# GitHub Repository Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn an approved GitHub discovery plan into a secure staged bare mirror, hidden repository, tested atomic publication/cleanup primitives, and conflict-review web flow while keeping publication gated on metadata.

**Architecture:** Git transfer runs through a supervised `GitCore.Remote` process-group boundary and writes only to an `importing` shadow repository with a new opaque storage path. Publication atomically activates that row; replacement tombstones the exact approved repository, preserves local authorization, and never mutates live Git storage in place.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto 3.14, git CLI, erlexec 2.3.4, PostgreSQL 17, dormant compile-only Turso Ecto compatibility, Phoenix 1.8, PhoenixDuskmoon 9.12

---

**Prerequisite:** Complete `docs/superpowers/plans/2026-08-25-github-import-foundation.md` first.

**Design:** `docs/superpowers/specs/2026-08-25-github-repository-organization-import-design.md`

**Database acceptance boundary (2026-08-29):** PostgreSQL 17 is the required
domain database for all remaining implementation and release gates. Use
`FORNACAST_DATABASE_ADAPTER=postgres` with an isolated `MIX_BUILD_PATH` and
`PGPORT=55432` for every database-backed command. Turso Ecto support is dormant
compile-only compatibility: do not run it as milestone acceptance and do not
weaken migrations or tests for it. Historical completed Turso evidence below is
retained only as history; every remaining unchecked gate in this plan is
PostgreSQL-only.

**Milestone boundary:** This plan implements and tests publication mechanics, but no production item reaches `ready_to_publish` and the web start action remains unavailable. `2026-08-25-github-metadata-import.md` stages supported metadata, enables start, and opens the publication gate so a code-only import can never become visible.

**Command convention:** Prefix Mix commands with:

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix <task-and-arguments>
```

Run focused PostgreSQL database suites with `--max-cases 1`.

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

Also assert PostgreSQL 17 rejection for an unknown lifecycle and generation zero
using the isolated PostgreSQL acceptance build.

- [ ] **Step 2: Run before migration**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_lifecycle_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix ecto.migrate
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_lifecycle_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/forge_repos_test.exs apps/forge_repos/test/access_test.exs apps/forge_issues/test/forge_issues_test.exs apps/forge_pulls/test/merge_reconciler_test.exs apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/users_organizations_test.exs apps/fornacast_api/test/graphql_test.exs apps/fornacast_web/test/repository_controller_test.exs apps/fornacast_web/test/fornacast_web_test.exs apps/git_transport/test/git_transport_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/forge_repos_test.exs apps/forge_repos/test/access_test.exs apps/forge_issues/test/forge_issues_test.exs apps/forge_pulls/test/merge_reconciler_test.exs apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/users_organizations_test.exs apps/fornacast_api/test/graphql_test.exs apps/fornacast_web/test/repository_controller_test.exs apps/fornacast_web/test/fornacast_web_test.exs apps/git_transport/test/git_transport_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_write_fence_test.exs apps/git_transport/test/receive_pack_fence_test.exs apps/fornacast_web/test/git_http_push_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_write_fence_test.exs apps/forge_repos/test/git_writes_test.exs apps/forge_repos/test/git_write_recovery_test.exs apps/forge_pulls/test/merge_recovery_test.exs apps/git_core/test/limits_test.exs apps/git_transport/test/receive_pack_fence_test.exs apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/git_http_push_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/git_core/test/remote_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/git_core/test/remote_test.exs apps/git_core/test/git_core_test.exs apps/git_core/test/limits_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/conflicts_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/conflicts_test.exs apps/forge_imports/test/import_persistence_test.exs apps/forge_imports/test/import_persistence_concurrency_test.exs apps/forge_imports/test/run_view_consistency_test.exs apps/forge_repos/test/repository_lifecycle_test.exs apps/forge_repos/test/git_write_recovery_test.exs apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_worker_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_worker_test.exs apps/forge_imports/test/discovery_recovery_test.exs apps/forge_accounts/test/forge_accounts_test.exs apps/git_core/test/remote_test.exs apps/forge_repos/test/repository_lifecycle_test.exs --max-cases 1
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
- Modify: `apps/forge_imports/test/run_view_consistency_test.exs`
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
`:persistence_unavailable`, `:publication_inconsistent`, and
`:invalid_request_metadata`.

The RED matrix must prove:

- the gate rejects every missing terminal sentinel and any wrong terminal
  `resource_kind`/`page_key`, `git_staged`, stale/non-running attempts, non-importing
  or changed shadows, and cleanup evidence; admission requires a selected
  `ready_to_publish` item, exact R6 Git proof, the current immutable running
  attempt, the importing hidden repository, and all five sentinels;
- active actor/run/item/attempt locking, a live foreign lease returning `:busy`,
  expired-lease reclamation, lease theft before the final CAS, concurrent callers,
  and exactly one winner; the winner increments `published_count` exactly once;
- invalid request metadata returns `:invalid_request_metadata` before actor, run,
  item, attempt, evidence, audit, or repository reads and before lease acquisition;
  attach to the existing Repo query telemetry event and assert zero queries, then
  prove no invalid request can reveal item existence or change a
  lock/version/timestamp;
- cancellation before intent returns `:cancelled` without publication, while
  cancellation after intent cannot move `publishing` to canceled, failed, or
  awaiting-credential and cannot interrupt recovery;
- a crashed/expired `publishing` worker reclaims the same persisted intent,
  operation ID, attempt number, action, hidden ID, and request metadata; it never
  creates a second intent;
- fresh `ready_to_publish` admission requires an active personal actor and a
  `running` run, while expired/due `publishing` recovery remains schedulable with a
  disabled actor and with the run in `running`, `cancel_requested`, or
  `awaiting_credential`; cancellation and credential wait do not interrupt an
  admitted publication, disabled-actor/authorization drift reopens only the item,
  and a terminal parent run returns `:publication_inconsistent` without recovery;
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
  item succeeds read-only even though the current count and `lock_version` are
  higher, while a lowered or mismatched count/version marker snapshot, changed audit
  snapshot/core, or current count/version lower than the agreed snapshots returns
  `:publication_inconsistent`;
- terminal replay first proves that the caller is the active personal actor owning
  the exact run/item; foreign and disabled actors receive `:not_found` before any
  evidence/audit/repository lookup, with no fact leakage and no writes;
- concurrent `get_run/2` reads around publication and capability-owned destination
  drift never combine an old parent count/state with a newly published or reopened
  child: in `run_view_consistency_test.exs`, reuse the Repo telemetry pause after the
  parent-run read, commit publication or drift before releasing the reader, and
  assert the final parent `lock_version` check retries to the wholly new view
  under concurrent PostgreSQL reads;
- destination drift closes only the current attempt, clears publication intent and
  lease, preserves that predecessor, and creates attempt `n + 1` on resolution;
  the successor resumes at `ready_to_publish` with an exact hidden repository, Git
  proof, and all five sentinels, at `git_staged` with reusable Git proof but
  incomplete metadata, or at `queued` only when no hidden/Git proof exists;
- request metadata, evidence, audit metadata, `Inspect`, errors, and public return
  values expose no PAT, authorization header, credential envelope, absolute storage
  path, or caller-controlled operation ID; and
- all admission, rollback, replay, audit-collision, and concurrency cases prove
  PostgreSQL locking, transaction, constraint, and replay behavior.

- [ ] **Step 2: Run before publisher exists**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_publication_test.exs --max-cases 1
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
           | :publication_inconsistent
           | :invalid_request_metadata}
def publish_repository(actor, item_id, request_metadata),
  do: RepositoryPublisher.publish(actor, item_id, request_metadata)
```

The first operation in `publish/3`, before any actor/item/evidence lookup or lease
transaction, is `ForgeAccounts.validate_github_request_metadata/1`. Return
`:invalid_request_metadata` unchanged on validation failure. For valid metadata,
retain only that normalized allowlisted projection, delete its `operation_id`, and
never honor the caller's value. Use
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

Split admission from recovery. `RepositoryPublisher.publish/3` is the fresh/public
path: it point-locks an active personal actor who owns the exact run/item, requires
the run to be `running`, and admits only `ready_to_publish`. An active publication
lease returns `:busy`. `RepositoryPublisher.recover/1` is an internal capability
path used for an already admitted `publishing` item: it requires no caller, GitHub
identity, saved credential, one-time envelope, or credential checkout. It may claim
only an expired/due lease whose persisted intent has exactly the shape above and
still matches the same item/current running attempt; it uses the persisted intent
and request metadata rather than new caller values.

Recovery accepts parent-run states `running`, `cancel_requested`, and
`awaiting_credential` and accepts either active or disabled persisted actor state,
so every durable intent remains schedulable. A `publishing` item under a terminal
run is inconsistent: return `:publication_inconsistent`, do not acquire a
publication fence, and do not reopen or mutate it. Change the ordinary
`RepositoryItem` transition matrix so `publishing` advances only to `published`; it
cannot become awaiting-credential, cancel-requested, canceled, or failed.
Cancellation therefore linearizes at the admission transaction: it wins before
intent, while a committed intent must finish or recover publication.

Immediately before any live repository mutation, the final transaction must reload
and lock the actor and destination authorization. If both are still active/valid,
finish publication even when the run is `cancel_requested` or
`awaiting_credential`. If actor state, namespace, target authorization, or other
destination facts drifted, roll back the publication Multi and call the dedicated
capability-owned reopening transaction in Step 5; never route recovery through the
active-user public drift path. A recoverable fence/reconciliation failure keeps the
item `publishing`, preserves the exact intent, clears only its own lease, and writes
a bounded `next_attempt_at`; failure to persist that release is
`:persistence_unavailable`.

Extend the existing serial `Reconciler` with two explicit eligibility branches.
Fresh due `ready_to_publish` requires an active personal actor, a `running` run,
and the exact current running attempt. Expired/due `publishing` requires the exact
current running attempt and a run state in
`[:running, :cancel_requested, :awaiting_credential]`, but deliberately does not
filter actor state or join any GitHub credential. Order `publishing` recovery first, then fresh
(`next_attempt_at IS NULL`) and oldest due work, then item ID. Invoke
`RepositoryPublisher.recover/1` for recovery and the fresh publisher path for new
admission from the existing one bounded scan task. Do not add a task, process,
supervisor, or publication concurrency.

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
user-ID order. Insert every collaborator user/role strictly; do not use
`on_conflict: :nothing` or permit a partial copy. Mutate the old row to `tombstoned`
with `deleted_at` first, run the test-only after-tombstone hook, and only then
activate the shadow.
Activation keeps the opaque storage path but may set generation from the current
immutable decision: `1` for create/rename or target generation plus one for replace.
That update is required so a drift successor can reuse already proven hidden Git
and metadata without recloning.

Make the locked active-actor and destination-authorization checks the contributor's
first `Multi.run` step. They execute immediately before any tombstone, collaborator,
or activation write. Thus a recovery scan may claim an intent owned by a now-disabled
actor to keep it schedulable, but it cannot touch either live repository before the
capability-owned drift path safely reopens the item.

For replacement, load the target only from the current decision and acquire
`ForgeRepos.with_import_publication_fence(target, :content, ...)`. Its existing
reconciler must settle durable Git writes and merges. Inside the callback, build one
final `Ecto.Multi`; its repository contributor again locks target/shadow by numeric
ID and compares the full fingerprint, including `write_version` and nullable
`last_pushed_at`. Never re-resolve the destination by slug.

That final Multi must atomically compose:

1. `ForgeRepos.publish_import_shadow/5`;
2. one CAS on the exact locked parent-run ID, allowed state, and `lock_version` that
   atomically sets `updated_at` and increments both `published_count` and
   `lock_version`, returning the post-update run with `run_id`,
   `published_count_after`, and
   `run_lock_version_after`;
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
  "published_count_after" => updated_run.published_count,
  "run_lock_version_after" => updated_run.lock_version
}
```

Merge those facts into the v1 intent rather than constructing an unrelated marker;
the resulting committed-evidence keyset is exactly the intent keyset with `state`
replaced plus the eight publication keys shown above. Construct exact audit core
metadata before merging the already normalized safe request metadata:

```elixir
imported_core = %{
  "item_id" => item.id,
  "attempt_number" => attempt.attempt_number,
  "run_id" => updated_run.id,
  "published_count_after" => updated_run.published_count,
  "run_lock_version_after" => updated_run.lock_version,
  "new_repository_id" => published.id
}

replaced_core = Map.put(imported_core, "old_repository_id", replaced.id)
```

`repository.imported` uses exactly `imported_core`; `repository.replaced` uses
exactly `replaced_core`. The stored audit metadata is exactly that core map merged
with the intent's safe request-metadata projection, and the collision verifier
compares the same projection.
Implement the run CAS as one adapter-neutral Multi step: PostgreSQL may use
`RETURNING`, while Turso performs the same guarded update then point-reads the row by
the exact incremented `lock_version` inside the transaction. Both branches return
the same post-update `%ImportRun{}` and a zero-row CAS aborts the whole Multi.
All five Multi contributions roll back together. Map destination namespace,
fingerprint, authorization, or shadow drift to `:destination_changed`; limiter,
fence, or writer/merge reconciliation failure to `:publication_unavailable`; and
database or audit failure to `:persistence_unavailable`.

- [ ] **Step 5: Make replay and destination-drift recovery exact**

For `published` and `completed`, take the read-only replay branch before admission.
After request metadata validation has succeeded, actor scope comes first: point-read
and require an active `kind: :user` actor,
then the exact actor-owned run and run-owned item; a stale struct, foreign actor, or
disabled actor returns `:not_found` before reading `publication_evidence`, attempt,
audit, replacement, or repository facts. This masking branch performs no writes.
Only after scope succeeds, use evidence, attempt number, new repository ID, and
optional old repository ID to perform indexed point reads and verify the exact
decision, active new repository settings/generation, old tombstone/deletion and
unchanged replacement facts, and
audit. Point-read the marker's `run_id`; require marker and audit to have the same
`published_count_after` and `run_lock_version_after`, and require the current run's
`published_count` and `lock_version` each to be greater than or equal to their
snapshot. Higher current values are expected after sibling publications or later
run touches and must not invalidate replay. The lease/item CAS plus the atomic
transaction is the exactly-once authority: replay never recomputes an O(n) item
count. Return the original `%{repository:, replaced:}` without a write. Any missing,
lowered, or mismatched marker/audit/run fact returns
`:publication_inconsistent`; never repair a committed marker heuristically.

On destination drift, use an internal capability containing exact run ID, run lock
version, item ID, attempt number, publication operation ID, lease owner, and item
lock version. A dedicated `Conflicts` transaction locks that actor row without
requiring it to be active, then locks the exact run/item/current attempt; verifies
the same admitted intent and lease; CAS-touches that exact parent-run ID, allowed
state, and `lock_version` by setting `updated_at` and incrementing `lock_version`
without changing `published_count`; closes only that running attempt as
`destination_changed`; clears publication intent/lease/backoff; and returns the item
to `awaiting_resolution`. The run touch, attempt close, and item reopen commit in the
same transaction so `get_run/2` cannot accept a torn parent/child view. Preserve the
hidden repository, Git evidence, metadata checkpoints, and immutable predecessor.
This is not the active-user public drift path and it performs no live-repository
write. Do not search by slug and do not mutate an older attempt.

When the user resolves the drifted item, create immutable attempt `n + 1` and derive
its resume state only from durable proof: `ready_to_publish` for the exact importing
shadow plus valid Git proof plus all five terminal sentinels; `git_staged` for the
exact shadow plus valid Git proof but incomplete metadata; `queued` only when both
hidden-repository and Git proof are absent. Contradictory partial evidence fails
closed. The current successor decision controls activation generation, so a changed
create/rename/replace choice can reuse the same valid shadow. Preserve every prior
attempt.

- [ ] **Step 6: Run the focused PostgreSQL publication suite**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/forge_imports/test/repository_publication_test.exs \
  apps/forge_imports/test/conflicts_test.exs \
  apps/forge_imports/test/import_persistence_test.exs \
  apps/forge_imports/test/import_persistence_concurrency_test.exs \
  apps/forge_imports/test/run_view_consistency_test.exs \
  apps/forge_imports/test/repository_worker_test.exs \
  apps/forge_repos/test/repository_lifecycle_test.exs \
  apps/forge_repos/test/repository_write_fence_test.exs \
  apps/forge_repos/test/git_write_recovery_test.exs \
  apps/forge_pulls/test/merge_recovery_test.exs \
  --max-cases 1
```

Expected: all focused tests pass on PostgreSQL; every failed publication leaves
the old repository ready and the shadow importing, committed replay performs no
writes, and PostgreSQL lease, row-lock, rollback, audit, replay, and handoff
behavior is proven.

- [ ] **Step 7: Commit publication**

```bash
git add apps/forge_imports apps/forge_repos apps/forge_pulls/test/merge_recovery_test.exs
git commit -m "feat(import): publish imported repositories"
```

### Task 8: Reclaim failed shadows and old tombstones safely

Task 8 is four ordered, independently committed slices. The scope expansion is
mandatory: cleanup deletes storage, while the current tree has neither an anchored
recursive-delete primitive nor a read lease covering the complete upload-pack
lifetime. A path check followed by `File.rm_rf/1` is a time-of-check/time-of-use
vulnerability and is forbidden.

The implementation must also reject all of these designs:

- path-based recursive deletion, including `File.rm_rf/1` after a containment,
  `lstat`, realpath, or identity check;
- cleanup without a `GitCore.RepositoryReadLimiter` exclusive cleanup permit;
- destructive observe mode: every delete requires an exact identity durably
  persisted before the destructive NIF call;
- sharing `ForgeImports.TaskSupervisor`, the sole import scan task, with cleanup;
- storing tombstone or unpublished-shadow intent in the narrow
  `RepositoryItem.cleanup_*` fields reserved for Remote quarantine recovery;
- deleting while a Git write, pull merge, or import operation is claimable;
- recording `repository.storage_reclaimed` or
  `github_import.quarantine_reclaimed` before the filesystem effect is proven;
- any Windows path fallback. Unsupported targets return a typed error without
  touching storage.

The filesystem threat model is Unix on Linux/macOS, with the service account
owning the repository tree under a same-UID, non-writable-by-other-users private
parent. No cleanup test may target the workspace, repository root, filesystem
root, or a shared directory; every destructive test uses ExUnit `tmp_dir`.

#### Task 8A: Add anchored filesystem identity and removal primitives

**Commit:** `feat(git): remove repository trees by anchored identity`

**Files:**

- Create: `apps/git_core/native/fornacast_git_core/src/anchored_remove.rs`
- Create: `apps/git_core/test/anchored_remove_test.exs`
- Modify: `apps/git_core/lib/git_core.ex`
- Modify: `apps/git_core/lib/git_core/native.ex`
- Modify: `apps/git_core/lib/git_core/remote.ex`
- Modify: `apps/git_core/native/fornacast_git_core/Cargo.toml`
- Modify: `apps/git_core/native/fornacast_git_core/Cargo.lock`
- Modify: `apps/git_core/native/fornacast_git_core/src/lib.rs`
- Modify: `apps/git_core/test/native_surface_test.exs`
- Modify: `apps/git_core/test/repository_read_model_test.exs`
- Modify: `apps/git_core/test/remote_test.exs`

- [ ] **Step 8A.1: Write the RED anchored-removal contract**

In `anchored_remove_test.exs`, create only private `tmp_dir` trees and assert this
exact public surface:

```elixir
@type contained_tree_identity :: %{
        mode: non_neg_integer(),
        major_device: non_neg_integer(),
        minor_device: non_neg_integer(),
        inode: pos_integer()
      }

@type contained_tree_proof :: %{
        root: contained_tree_identity(),
        target: contained_tree_identity()
      }

@spec GitCore.contained_tree_identity(Path.t(), [String.t()], non_neg_integer()) ::
        {:ok, {:present, contained_tree_proof()}}
        | {:ok, {:missing, contained_tree_identity()}}
        | {:error, atom()}

@spec GitCore.remove_contained_tree(
        Path.t(),
        [String.t()],
        contained_tree_proof(),
        non_neg_integer()
      ) ::
        {:ok, {:removed, contained_tree_proof()}}
        | {:ok, {:missing, contained_tree_identity()}}
        | {:error, atom()}
```

This is the only directory-identity shape in Task 8. Public GitCore maps use the
four atom keys above; persisted JSON uses exactly `"mode"`,
`"major_device"`, `"minor_device"`, and `"inode"` with the same integer
values. Reject missing/extra keys, non-integers, negative mode/major/minor values,
and zero/negative inode. No API, Rust struct, journal evidence, or comparison
stores raw `st_dev` or a `device` field.

Cover exact present-proof success and replay; independent expected root and target
`mode`, `major_device`, `minor_device`, and `inode` mismatch;
missing target reached through an anchored parent, root symlink, ancestor symlink,
target symlink, nested symlink, a target-name swap between observation and removal,
configured-root replacement after observation and before traversal/final unlink,
FIFO/socket/device-node/special-file rejection, regular nested files and directories,
absolute/empty/`.`/`..` segments, NUL, backslash, segment/count/depth/entry bounds,
deadline zero, partial timeout followed by exact-identity replay, and a descendant
mount/filesystem-device crossing when the test host permits an unprivileged mount.
If the mount cannot be created, explicitly assert the test is skipped for that
host; do not weaken the production `major_device/minor_device` check.

In `remote_test.exs`, exercise three real-filesystem paths: a mirror failure that
renames into its deterministic quarantine, `GitCore.Remote.cleanup_evidence/1`
rediscovery, and prior-slot discovery on the next mirror attempt. For the same
quarantine, assert every returned `CleanupPending.identity` equals the `target` in
the `{:present, %{root: root_identity, target: target_identity}}` result from
`GitCore.contained_tree_identity(parent, [leaf], deadline_ms)`. Require exact
`%{mode: 0o700, major_device:, minor_device:, inode:}` equality across all three
paths. Also assert `root_identity` is the final nofollow-opened parent directory
and both atom-key public maps round-trip to persisted JSON string-key maps without
value conversion.

These tests are RED against the current Remote implementation because OTP
`File.Stat.major_device/minor_device` expose platform raw `st_dev/st_rdev` fields;
they are not the canonical `major(st_dev)/minor(st_dev)` pair. Do not change
`RepositoryWorker` persistence, which already stores the desired four key names.

Add source assertions that `anchored_remove.rs` uses descriptor-relative
`openat`/`statat`/`unlinkat` operations, contains no path fallback, compiles an
unsupported-platform branch that returns `:unsupported_platform`, and that no
production Task 8 module contains `File.rm_rf`. Add strict cache tests showing the
existing `invalidate_repository_cache/1` remains fail-open for read callers while
`invalidate_repository_cache_strict/1` returns `{:error, :cache_unavailable}` when
the cache process is absent or crashes.

- [ ] **Step 8A.2: Run the RED tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/git_core/test/anchored_remove_test.exs \
  apps/git_core/test/native_surface_test.exs \
  apps/git_core/test/repository_read_model_test.exs \
  apps/git_core/test/remote_test.exs \
  --max-cases 1
```

Expected: FAIL because the two anchored APIs and strict invalidation API do not
exist; once those compile, the Remote cases still fail until raw File.Stat cleanup
identity is replaced by anchored canonicalization.

- [ ] **Step 8A.3: Implement one anchored DirtyIo NIF per public call**

Add direct `rustix = { version = "1.1.4", features = ["fs"] }` to `Cargo.toml`;
the exact version is already transitively locked, so `Cargo.lock` must retain
`rustix 1.1.4` without a second rustix version. Export exactly two Rustler
`schedule = "DirtyIo"` NIFs from `lib.rs`:

```rust
#[rustler::nif(schedule = "DirtyIo")]
fn contained_tree_identity(
    storage_root: String,
    relative_segments: Vec<String>,
    deadline_ms: u64,
) -> Result<IdentityResult, AnchoredRemoveError>;

#[rustler::nif(schedule = "DirtyIo")]
fn remove_contained_tree(
    storage_root: String,
    relative_segments: Vec<String>,
    expected_proof: ContainedTreeProof,
    deadline_ms: u64,
) -> Result<RemoveResult, AnchoredRemoveError>;
```

`ContainedTreeIdentity` has exactly `mode: u32`, `major_device: u32`,
`minor_device: u32`, and positive `inode: u64`. `IdentityResult` is exactly
`Present(ContainedTreeProof) | Missing(ContainedTreeIdentity)`, where
`ContainedTreeProof` contains exact `root` and `target` identities.
`RemoveResult` is exactly
`Removed(ContainedTreeProof) | Missing(ContainedTreeIdentity)`. The companion on
`Missing` is the current final-opened configured storage-root identity. Rustler
encodes these to the public Elixir tuples from Step 8A.1.

Register matching stubs in `GitCore.Native` and wrappers in `GitCore`. The wrappers
accept only a non-root absolute `storage_root`, a non-empty list of canonical
relative segments, an exact root+target proof for removal, and a nonnegative integer
deadline. Invalid Elixir terms return `{:error, :invalid_argument}` without
entering Rust.

For both NIFs, open the absolute storage root by walking from `/` one component at
a time with `openat(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`. Then walk every
relative component from the anchored root descriptor with the same flags. At each
hop use `fstat` plus `statat(..., AT_SYMLINK_NOFOLLOW)` and reject a symlink,
non-directory, four-field identity disagreement, filesystem-device crossing, or
deadline expiry.
Reject absolute, empty, `.`, `..`, embedded-NUL, backslash, oversized, over-depth,
and over-count input before traversal.

On Linux and macOS, construct every directory identity as permission
`mode = st_mode & 0o777`, `major_device = rustix::fs::major(st_dev)`,
`minor_device = rustix::fs::minor(st_dev)`, and positive `inode = st_ino`.
Use these rustix platform helpers rather than copying or casting raw `st_dev`.
Compare descendant filesystem membership by the root `major_device/minor_device`
pair while retaining the full stat mode separately for directory/special-file
classification.

In `GitCore.Remote`, keep the existing private `File.Stat` tuple only for immediate
same-path race checks such as comparing a directory immediately before and after a
rename/validation step. Name those values as raw stat fields; never expose them,
persist them, compare them with canonical identities, or relabel them as
`major_device/minor_device`.

After a quarantine rename and safe-path validation, call
`GitCore.contained_tree_identity(parent, [leaf], deadline_ms)`, require
`{:present, %{target: %{mode: 0o700} = canonical_target}}`, and build
`CleanupPending.identity` from that canonical target. Apply the same anchored
canonicalization in `cleanup_evidence/1` and every prior deterministic-slot
discovery path before returning cleanup-pending evidence. Missing, non-`0700`,
root/target mismatch, or typed anchored error remains
`GitCore.Remote.Error{kind: :unsafe_cleanup_state}`. No Remote branch may derive a
public/persisted identity directly from `File.lstat/1`.

`contained_tree_identity/3` is read-only and returns the exact target
as `{:present, %{root: root_identity, target: target_identity}}`, where
`root_identity` is the final configured storage-root directory opened by the
absolute nofollow walk. It returns `{:missing, root_identity}` only after safely
reaching the anchored parent.

`remove_contained_tree/4` has no observe or target-only mode. It first reopens the
configured storage root through the same nofollow walk and compares all four root
fields to `expected_proof.root`, then compares all four target fields to
`expected_proof.target` before preflight. It preflights the complete tree
descriptor-relatively within depth/entry/deadline/filesystem-device limits, then
removes regular files with `unlinkat` and directories with
`unlinkat(..., AT_REMOVEDIR)` without following links. Immediately before the
final target `AT_REMOVEDIR`, reopen the configured root by name and recompare both
root and target identities. Root replacement returns `:root_changed` and leaves
the newly named tree untouched. Remove the target root last.

On a partial timeout/error, preserve the target root inode whenever possible so
replay with the same persisted root+target proof can finish. A safely absent target
returns `{:missing, current_root_identity}` only after anchored-parent proof; the
caller must compare all four current-root fields with the persisted pre-delete
root before finalization. Never translate an unsafe lookup failure into missing.

The typed error atoms are:

```elixir
[
  :invalid_argument,
  :unsupported_platform,
  :not_found,
  :symlink,
  :special_file,
  :filesystem_device_changed,
  :identity_mismatch,
  :mode_mismatch,
  :root_changed,
  :depth_limit,
  :entry_limit,
  :deadline_exceeded,
  :permission_denied,
  :io_error
]
```

On non-Unix targets and Unix targets other than Linux/macOS, both NIFs return
`:unsupported_platform` before opening anything. There is no Rust standard-library
path recursion and no Elixir fallback.

- [ ] **Step 8A.4: Implement strict cache invalidation**

Add:

```elixir
@spec invalidate_repository_cache_strict(Path.t()) ::
        :ok | {:error, :cache_unavailable}
def invalidate_repository_cache_strict(repository_path)
    when is_binary(repository_path) do
  case GitCore.Cache.invalidate_repository(repository_path) do
    :ok -> :ok
    _ -> {:error, :cache_unavailable}
  end
catch
  _kind, _reason -> {:error, :cache_unavailable}
end
```

Keep `invalidate_repository_cache/1` unchanged. Cleanup is the only initial caller
of the strict form.

- [ ] **Step 8A.5: Run GREEN native and Elixir checks**

```bash
devenv shell -- cargo test \
  --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml \
  anchored_remove -- --nocapture
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test \
  apps/git_core/test/anchored_remove_test.exs \
  apps/git_core/test/native_surface_test.exs \
  apps/git_core/test/repository_read_model_test.exs \
  apps/git_core/test/remote_test.exs \
  --max-cases 1
```

Expected: all tests pass, the success case reports the same root+target proof
observed before removal, root/target mismatch cases leave the target untouched,
partial-timeout replay removes only the original target under the original root,
and mirror-failure, cleanup-evidence, and prior-slot Remote results all expose the
same anchored canonical target identity.

- [ ] **Step 8A.6: Commit the anchored primitive**

```bash
git diff --check
git add \
  apps/git_core/lib/git_core.ex \
  apps/git_core/lib/git_core/native.ex \
  apps/git_core/lib/git_core/remote.ex \
  apps/git_core/native/fornacast_git_core/Cargo.toml \
  apps/git_core/native/fornacast_git_core/Cargo.lock \
  apps/git_core/native/fornacast_git_core/src/lib.rs \
  apps/git_core/native/fornacast_git_core/src/anchored_remove.rs \
  apps/git_core/test/anchored_remove_test.exs \
  apps/git_core/test/native_surface_test.exs \
  apps/git_core/test/repository_read_model_test.exs \
  apps/git_core/test/remote_test.exs
git commit -m "feat(git): remove repository trees by anchored identity"
```

#### Task 8B: Lease repository readers and cleanup

**Commit:** `feat(git): lease repository readers`

**Files:**

- Create: `apps/git_core/lib/git_core/repository_read_limiter.ex`
- Create: `apps/git_core/test/repository_read_limiter_test.exs`
- Create: `apps/forge_repos/lib/forge_repos/repository_read_handle.ex`
- Create: `apps/forge_repos/test/repository_read_handle_test.exs`
- Create: `apps/forge_repos/test/repository_read_callsite_audit_test.exs`
- Modify: `apps/git_core/lib/git_core/application.ex`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/test/forge_repos_test.exs`
- Modify: `apps/forge_pulls/lib/forge_pulls.ex`
- Modify: `apps/forge_pulls/test/forge_pulls_test.exs`
- Modify: `apps/git_transport/lib/git_transport/upload_pack.ex`
- Modify: `apps/git_transport/lib/git_transport/exec.ex`
- Modify: `apps/git_transport/lib/git_transport/channel.ex`
- Modify: `apps/git_transport/test/git_transport_test.exs`
- Modify: `apps/git_transport/test/test_dirty_io_native_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/repository_page.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`
- Modify: `apps/fornacast_web/test/git_http_auth_test.exs`
- Modify: `apps/fornacast_web/test/repository_controller_test.exs`
- Modify: `apps/fornacast_web/test/repository_page_test.exs`

- [ ] **Step 8B.1: Write the RED read/cleanup lease matrix**

Define the limiter interface exactly:

```elixir
@spec GitCore.RepositoryReadLimiter.acquire_read(
        pos_integer(),
        integer()
      ) :: {:ok, lease()} | {:error, :deadline_exceeded | :unavailable}

@spec GitCore.RepositoryReadLimiter.acquire_cleanup(
        pos_integer(),
        integer()
      ) :: {:ok, lease()} | {:error, :deadline_exceeded | :unavailable}

@spec GitCore.RepositoryReadLimiter.release(lease()) :: :ok
```

The deadline is an absolute monotonic millisecond deadline used only while
acquiring. A granted lease lives until explicit release or owner-process death.
Test multiple shared readers, one exclusive cleanup grant, cleanup waiting for
existing readers, writer-priority behavior where readers arriving after queued
cleanup wait behind it, acquisition deadline expiry, independent repositories,
owner death, idempotent release, limiter absence, limiter crash, and recovery.

The limiter uses a pending/confirmed production registry around the GenServer
call, monitors every owner, has `restart: :temporary`, and fails closed when absent
or during a crash. On restart it restores only confirmed grants whose owner PIDs
are still alive, discards pending/dead grants, and rebuilds monitors and
per-repository queues. Match the established
`RepositoryWriteLimiter` crash-window tests, but do not change its semantics or
make ordinary writers acquire the new limiter.

- [ ] **Step 8B.2: Run the limiter RED tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test \
  apps/git_core/test/repository_read_limiter_test.exs \
  --max-cases 1
```

Expected: FAIL because `RepositoryReadLimiter` does not exist.

- [ ] **Step 8B.3: Implement the limiter and deep ForgeRepos read handle**

Add `GitCore.RepositoryReadLimiter` to `GitCore.Application.child_specs/0` after
`RepositoryWriteLimiter`. Use per-repository FIFO queues with this grant rule:
shared reads may co-exist only before cleanup is queued; one cleanup lease requires
zero readers; after cleanup is queued, later reads remain queued; a grant on one
repository never blocks another repository.

Expose an opaque handle rather than a repository/path tuple:

```elixir
defmodule ForgeRepos.RepositoryReadHandle do
  @opaque t :: %__MODULE__{}
  @enforce_keys [:repository, :path, :lease]
  defstruct @enforce_keys
end

@spec ForgeRepos.open_repository_read(Repository.t(), integer()) ::
        {:ok, RepositoryReadHandle.t()}
        | {:error, :not_found | :deadline_exceeded | :unavailable}

@spec ForgeRepos.close_repository_read(RepositoryReadHandle.t()) :: :ok

@spec ForgeRepos.repository_read_repository(RepositoryReadHandle.t()) ::
        Repository.t()

@spec ForgeRepos.repository_read_path(RepositoryReadHandle.t()) :: Path.t()

@spec ForgeRepos.with_repository_read(
        Repository.t(),
        integer(),
        (RepositoryReadHandle.t() -> result)
      ) :: result | {:error, :not_found | :deadline_exceeded | :unavailable}
      when result: term()
```

`open_repository_read/2` acquires the read lease for the input repository ID,
reloads that exact ID, and requires exact input generation, `lifecycle: :ready`,
`deleted_at: nil`, `storage_reclaimed_at: nil`, and a canonical contained storage
path. Release immediately on every reload/path mismatch. The returned handle owns
the reloaded repository and absolute path. `close_repository_read/1` is
idempotent. `RepositoryReadHandle` exports no constructor, field accessor, or
lease accessor. `ForgeRepos.open_repository_read/2` alone constructs it;
`ForgeRepos` alone pattern-matches it for the two projections and close.
`close_repository_read/1` is the only function that reads/releases the private
limiter lease, and repeated close remains safe.

`repository_read_repository/1` and `repository_read_path/1` are the only public
projections. `with_repository_read/3` calls `open_repository_read/2`, invokes the
one-arity function with the opaque handle, and always closes in `after`; it catches
neither returned errors nor exceptions. The callback does not receive a struct
shape or lease. These functions are the only read-side APIs that may cross
publication/deletion boundaries.

- [ ] **Step 8B.4: Move every ready-repository GitCore read behind the handle**

Change `GitTransport.UploadPack.advertise_refs/1`, `response/2`, and `serve/1`
repository wrappers to acquire/release a handle. Add internal
`advertise_refs_handle/1` and `response_handle/2` functions that accept only the
opaque handle so a long-lived caller can retain one lease across multiple protocol
phases. They obtain the reloaded repository/path only through
`ForgeRepos.repository_read_repository/1` and
`ForgeRepos.repository_read_path/1`.

`GitTransport.Exec` and Git-over-HTTP use the same wrapper seam with
`try ... after ForgeRepos.close_repository_read(handle) end`. Repository lookup
still happens before the tombstone race, but handle acquisition after a tombstone
must fail without touching storage.

For SSH, `GitTransport.Channel` acquires the handle before advertisement, stores it
in a new `repository_read_handle` field, and uses that same handle through
advertisement, negotiation, pack generation, and send completion. Release and
clear it on every normal completion, protocol error, send error, EOF, closed
message, rejection after acquisition, and `terminate/2`; repeated cleanup is safe.
The limiter owner monitor is the final fallback if the channel dies.

Wrap every production ready-repository GitCore read for its complete native/cache
sequence, not merely upload-pack:

- in `ForgeRepos`, run `repository_view/2` and list-view disk-usage reads through
  `with_repository_read/3`, using `repository_read_repository/1` and
  `repository_read_path/1`; also wrap the default-branch `resolve_snapshot`
  validation that is not already inside a writer fence;
- in `ForgePulls`, wrap public `branch_options/2`, `compare/5`,
  `list_commits/4`, `changed_files/4`, ref resolution, comparison/diff, commit
  paging, and merge-analysis refreshes that are not already inside the existing
  writer fence. A multi-call comparison uses one handle for its whole snapshot;
- in `FornacastWeb.RepositoryPage` and `RepositoryController`, acquire once around
  each page/raw request and pass values returned by the two ForgeRepos accessors
  through code, tree, blob/raw, refs, commits/history, commit, search, analysis,
  and disk-usage reads. Page-result cleanup remains responsible only for its
  existing blob/scan permits; the repository read lease closes after the complete
  GitCore result is materialized.

`GitTransport.UploadPack`, `ForgePulls`, and every web module treat the callback
argument as opaque: they call the two ForgeRepos projections or a deeper
handle-taking API and never pattern-match, destructure, inspect, or access fields.

Reads already enclosed by `GitCore.RepositoryWriteLimiter` are explicitly exempt:
receive-pack, `GitWriteRecovery`, `MergeRecovery`, and final merge
analysis/write/ref-advance. Cleanup also holds that writer limiter, so they cannot
overlap deletion. Importing-shadow reads are exempt only while their exact
run/item/attempt lease and cleanup-journal rules make the shadow ineligible; no
ready repository may use that exemption.

Create `repository_read_callsite_audit_test.exs` to scan production Elixir sources
for every `GitCore.*` invocation. Maintain an exact allowlist containing only
handle-based ready reads, the writer-fenced calls above, and identified
importing-shadow calls with their owning import lease. Fail on any unclassified
callsite or any allowlist entry that disappears, so a new ready read cannot bypass
the lease silently. The same audit rejects external
`%RepositoryReadHandle{}` patterns, field access, `Map.get/fetch` on handles,
`Kernel.get_in`, and any lease accessor. The handle module only declares the
opaque struct; only `ForgeRepos` may construct or destructure it.

Add integration assertions that an old reader opened before replacement continues
using the old inode and blocks cleanup, while a post-publication lookup opens the
new repository. Hold the read lease across a deliberately blocked DirtyIo pack NIF
for SSH and HTTP, prove cleanup waits, then release and prove cleanup wins. Also
prove `Exec.upload_pack/3` and `upload_pack_stream/3` use the same handle seam.
Block GitCore test doubles inside repository view/size, web browse/search/blob,
pull branch/commit/diff/compare/analysis, HTTP, and SSH paths and prove an exclusive
cleanup grant waits for each. Conversely, hold cleanup, queue each reader, perform
strict invalidation and removal, then prove no queued read executes GitCore or
repopulates `GitCore.Cache` after invalidation.

In `repository_read_handle_test.exs`, assert both accessors return the reloaded
repository/path, no public lease accessor exists, external code never sees the
lease, and close is idempotent across success, raised callback, and owner death.

- [ ] **Step 8B.5: Run GREEN read-path tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test \
  apps/git_core/test/repository_read_limiter_test.exs \
  apps/forge_repos/test/repository_read_handle_test.exs \
  apps/forge_repos/test/repository_read_callsite_audit_test.exs \
  apps/forge_repos/test/forge_repos_test.exs \
  apps/forge_pulls/test/forge_pulls_test.exs \
  apps/git_transport/test/git_transport_test.exs \
  apps/git_transport/test/test_dirty_io_native_test.exs \
  apps/fornacast_web/test/git_http_auth_test.exs \
  apps/fornacast_web/test/repository_controller_test.exs \
  apps/fornacast_web/test/repository_page_test.exs \
  --max-cases 1
devenv shell -- mix dialyzer --format raw
```

Expected: all tests pass; cleanup cannot overlap repository view/size, pull,
browser, SSH, Exec, HTTP, or blocked DirtyIo reads; limiter failure denies new
reads; and no read runs or repopulates cache after strict invalidation. Dialyzer
reports no `:opaque_match`, `:call_without_opaque`, or other opaque-type warning;
adding external field access to the audit fixture must make the audit and Dialyzer
expectation fail.

- [ ] **Step 8B.6: Commit reader leasing**

```bash
git diff --check
git add \
  apps/git_core/lib/git_core/application.ex \
  apps/git_core/lib/git_core/repository_read_limiter.ex \
  apps/git_core/test/repository_read_limiter_test.exs \
  apps/forge_repos/lib/forge_repos.ex \
  apps/forge_repos/lib/forge_repos/repository_read_handle.ex \
  apps/forge_repos/test/repository_read_handle_test.exs \
  apps/forge_repos/test/repository_read_callsite_audit_test.exs \
  apps/forge_repos/test/forge_repos_test.exs \
  apps/forge_pulls/lib/forge_pulls.ex \
  apps/forge_pulls/test/forge_pulls_test.exs \
  apps/git_transport/lib/git_transport/upload_pack.ex \
  apps/git_transport/lib/git_transport/exec.ex \
  apps/git_transport/lib/git_transport/channel.ex \
  apps/git_transport/test/git_transport_test.exs \
  apps/git_transport/test/test_dirty_io_native_test.exs \
  apps/fornacast_web/lib/fornacast_web/repository_page.ex \
  apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex \
  apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex \
  apps/fornacast_web/test/git_http_auth_test.exs \
  apps/fornacast_web/test/repository_controller_test.exs \
  apps/fornacast_web/test/repository_page_test.exs
git commit -m "feat(git): lease repository readers"
```

#### Task 8C: Persist cleanup intent and expose fail-closed safety ports

**Commit:** `feat(import): persist repository cleanup intent`

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260825000430_add_import_cleanup_recovery.exs`
- Create: `apps/forge_imports/lib/forge_imports/cleanup_operation.ex`
- Create: `apps/forge_imports/test/cleanup_operation_test.exs`
- Create: `apps/forge_imports/test/cleanup_recovery_migration_test.exs`
- Modify: `apps/fornacast/lib/fornacast/operation_lease.ex`
- Modify: `apps/git_core/lib/git_core/remote.ex`
- Modify: `apps/git_core/test/remote_test.exs`
- Modify: `apps/forge_repos/lib/forge_repos/git_write_operation.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_operation.ex`
- Modify: `apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex`
- Modify: `apps/forge_repos/lib/forge_repos/git_write_recovery.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_recovery.ex`
- Modify: `apps/forge_imports/lib/forge_imports/persistence.ex`
- Modify: `apps/forge_imports/lib/forge_imports/conflicts.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_publisher.ex`
- Modify: `apps/forge_imports/test/import_persistence_test.exs`
- Modify: `apps/forge_imports/test/import_persistence_concurrency_test.exs`
- Modify: `apps/forge_imports/test/conflicts_test.exs`
- Modify: `apps/forge_imports/test/repository_publication_test.exs`
- Modify: `apps/forge_repos/test/git_writes_test.exs`
- Modify: `apps/forge_repos/test/git_write_recovery_test.exs`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`
- Modify: `config/config.exs`

- [ ] **Step 8C.1: Write the RED migration, schema, lease, and port tests**

The migration creates `github_import_repository_cleanups` with:

```text
repository_id              bigint, required
repository_item_id         bigint, required
source_lock_version        bigint, required
kind                       remote_quarantine | unpublished_shadow | replacement_tombstone
state                      cleanup_pending | cleanup_blocked | cleanup_complete
operation_id               string, required
evidence                   map/json, required
eligible_at                utc_datetime, required
next_attempt_at            utc_datetime, nullable
attempt_count              integer, required, default 0
last_error                 string, nullable
effect_started_at          utc_datetime, nullable
effect_finished_at         utc_datetime, nullable
completed_at               utc_datetime, nullable
lease_owner                string, nullable
lease_expires_at           utc_datetime, nullable
lock_version               integer, required, default 0
inserted_at/updated_at      utc_datetime, required
```

Add named checks for the three enums, positive IDs/source version, nonnegative
attempt/version, paired leases, state/completion/effect timestamps, and exact
state/evidence/lease coherence. Add foreign keys to repositories and repository
items, a unique `operation_id` index, a unique
`repository_item_id/kind/source_lock_version` index, and recovery index
`state/next_attempt_at/eligible_at/id`.

The exact lifecycle coherence is: pending requires `next_attempt_at`, has no
`completed_at`, and may have no effect timestamps, only `effect_started_at`, or
both effect timestamps; blocked requires classified `last_error`, has no lease,
`next_attempt_at`, or `completed_at`, and may retain ordered effect timestamps;
complete has no lease, `next_attempt_at`, or `last_error` and requires
`effect_started_at`, `effect_finished_at`, and `completed_at` in timestamp order.
Only pending may carry a lease, and `effect_finished_at` never exists without
`effect_started_at`. Every evidence map passes the exact per-kind version/key/type
validator below. Once `effect_started_at` is present, the evidence contains
exactly one immutable anchored outcome: the co-present
`root_identity + anchored_identity` pair, or `anchored_absence`, never a partial
pair and never both branches.

The same migration adds named checks to `git_write_operations` and
`pull_merge_operations`: `lease_owner` and `lease_expires_at` are both null or
both non-null, and terminal rows retain neither. Implement exact adapter-specific
`up/0` and `down/0`. On Turso, use the repository's established table-rebuild
rollback guard required by `gsmlg-dev/concord#81`; do not open a new upstream issue
for this approved slice.

Test every cleanup state/evidence/lease combination at the changeset and PostgreSQL
17 database levels using the isolated PostgreSQL acceptance build. `Inspect` must
redact `evidence`, `last_error`, and
every path-bearing field. Add `states/0` and `terminal_states/0` to
`GitWriteOperation` and `MergeOperation` so `OperationLease.claim/5` returns
`:busy` for terminal rows. Verify existing live nonterminal claims still work and
one-sided or terminal retained leases are rejected by PostgreSQL constraints.
Include valid present root+target evidence, valid initial-absence evidence, missing
present-root or present-target failures, present/absence mutual-exclusion
failures, mismatched absolute/relative joins, malformed canonical segments,
absence without ordered effect timestamps, and complete present/absence-proof rows
in the PostgreSQL migration/schema matrix. Application tests separately cover
live-config root drift because the database does not own runtime configuration.
In `remote_test.exs`, prove two canonical absolute requested destinations with the
same basename under different parents produce different slots, a real Remote
quarantine round-trips through the helper, and a slot derived from basename alone
is rejected by CleanupOperation application validation.

- [ ] **Step 8C.2: Run the PostgreSQL RED suite**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/forge_imports/test/cleanup_operation_test.exs \
  apps/forge_imports/test/cleanup_recovery_migration_test.exs \
  apps/git_core/test/remote_test.exs \
  apps/forge_repos/test/git_writes_test.exs \
  apps/forge_pulls/test/merge_recovery_test.exs \
  --max-cases 1
```

Expected: FAIL because migration `00430` and `CleanupOperation` are absent and the
two existing operation schemas do not expose terminal states.

- [ ] **Step 8C.3: Implement the cleanup journal schema and exact evidence**

`CleanupOperation` exposes:

```elixir
def states, do: [:cleanup_pending, :cleanup_blocked, :cleanup_complete]
def terminal_states, do: [:cleanup_blocked, :cleanup_complete]
def kinds, do: [:remote_quarantine, :unpublished_shadow, :replacement_tombstone]
```

Expose the existing Remote slot authority narrowly:

```elixir
@doc false
@spec GitCore.Remote.cleanup_slot_path(Path.t()) :: Path.t()
```

`cleanup_slot_path/1` is pure and has no filesystem effect. For a canonical
absolute requested destination it applies the existing exact domain-separated hash
to the full absolute destination and returns the deterministic absolute
`.fornacast-cleanup-v1-*` sibling. The mirror failure/rename path,
`cleanup_evidence/1`, and prior-slot discovery all call this helper; no second slot
algorithm remains.

Its creation changeset accepts immutable identity/evidence fields plus scheduling
fields only. Its `lease_update_changeset/2` permits exact transitions from pending
to pending/blocked/complete, attempt/backoff/error updates, anchored-outcome
enrichment, effect timestamps, and completion; enrichment chooses exactly one
immutable anchored identity-or-absence outcome. It never permits changing
repository, item, source version, kind, operation ID, or original evidence facts.

Use these deterministic operation IDs:

```elixir
"github-import-cleanup:remote_quarantine:#{repository_id}:#{item_id}:#{source_lock_version}"
"github-import-cleanup:unpublished_shadow:#{repository_id}:#{item_id}:#{source_lock_version}"
"github-import-cleanup:replacement_tombstone:#{repository_id}:#{item_id}:#{source_lock_version}"
```

Use version `1` evidence maps with exact keys:

- replacement tombstone:
  `version, kind, storage_root, relative_path, repository_id,
  repository_generation, repository_write_version, repository_storage_path,
  repository_deleted_at, repository_updated_at, item_id, item_lock_version,
  attempt_number, attempt_decision, attempt_fingerprint, publication_operation_id,
  publication_marker, new_repository_id, new_repository_generation,
  publication_audit_id`;
- unpublished shadow:
  `version, kind, storage_root, relative_path, repository_id,
  repository_generation, repository_write_version, repository_storage_path,
  repository_updated_at, item_id, item_lock_version, item_state, run_id, run_state,
  attempt_number, attempt_state, attempt_decision, attempt_fingerprint,
  publication_evidence, predecessor_item_id, successor_item_id, adopter_item_id`;
- Remote quarantine:
  `version, kind, storage_root, relative_path, repository_id,
  repository_generation, repository_storage_path, item_id, item_lock_version,
  requested_path, quarantine_path, mode, major_device, minor_device, inode,
  remote_failure_kind`.

`storage_root` is the canonical absolute configured repository root and
`relative_path` is the canonical relative slash path from that root to the cleanup
target. Replacement/unpublished evidence requires
`relative_path == repository_storage_path`. Remote evidence requires:

```elixir
requested_path == Path.join(storage_root, repository_storage_path)
quarantine_path == Path.join(storage_root, relative_path)
quarantine_path == GitCore.Remote.cleanup_slot_path(requested_path)
relative_path == Path.relative_to(quarantine_path, storage_root)
```

The Remote leaf is the deterministic `.fornacast-cleanup-v1-*` sibling under the
same relative parent. CleanupOperation application validation calls
`cleanup_slot_path(requested_path)` at creation and rejects basename-only hashing
or any other slot. Database checks enforce the persisted absolute joins, same
root/parent, reserved cleanup-leaf prefix, length/character syntax, and canonical
path structure; they do not recompute the SHA.

Every persisted target or root identity validator accepts only the canonical
string-key JSON shape
`%{"mode" => nonnegative, "major_device" => nonnegative,
"minor_device" => nonnegative, "inode" => positive}`. It rejects raw `device`,
unknown keys, and lossy numeric conversion.

After anchored observation, enrich the same evidence with exactly one of:

```elixir
%{
  "root_identity" => %{
    "mode" => root_mode,
    "major_device" => root_major_device,
    "minor_device" => root_minor_device,
    "inode" => root_inode
  },
  "anchored_identity" => %{
    "mode" => target_mode,
    "major_device" => target_major_device,
    "minor_device" => target_minor_device,
    "inode" => target_inode
  }
}

%{
  "anchored_absence" => %{
    "version" => 1,
    "observed_at" => DateTime.to_iso8601(observed_at),
    "root_identity" => %{
      "mode" => root_mode,
      "major_device" => root_major_device,
      "minor_device" => root_minor_device,
      "inode" => root_inode
    }
  }
}
```

The present branch is the persisted form of
`%{root: root_identity, target: target_identity}`. `root_identity` and
`anchored_identity` are inserted in one lease-owned update and are jointly
immutable; neither is valid without the other.

`anchored_absence` has exactly `version, observed_at, root_identity`. It inherits
root/path exclusively from immutable base `storage_root` and `relative_path`;
neither anchored branch duplicates or hashes path evidence. `root_identity` is the
canonical four-field atom-key companion returned with
`{:missing, root_identity}`, converted without value changes to the JSON string-key
shape shown above. The original base/path evidence and chosen anchored outcome
remain immutable. A present outcome is valid only after the read-only anchored NIF
returned a full root+target proof. An absence outcome is valid only after that NIF
returned `{:missing, root_identity}` under both permits; it is not permission to
call removal.

At journal creation, application validation requires
`storage_root == Fornacast.Config.repo_storage_root()` after canonical expansion,
validates `relative_path` as nonempty canonical slash segments, reconstructs the
contained absolute target, and enforces the per-kind relationships above.
Enrichment revalidates the immutable base and cannot change it.

Both adapter migrations/checks enforce exact evidence/anchored keysets, JSON field
types, identity numeric ranges, kind/state enums, timestamp ordering, canonical
absolute/relative string shape, and all internal path equalities expressible from
persisted inputs. They do not hash ETF, call a digest/UDF, or claim to authenticate
application configuration. The database cannot know the current runtime root;
Task 8D supplies that external fact before every effect/finalization. A row forged
with raw SQL may satisfy internal DB relationships, but live-config/path preflight
must still reject it before filesystem access.
`publication_marker` is the full committed marker already validated by
`RepositoryPublisher`. `attempt_fingerprint` is lowercase hex SHA-256 of the
canonical Erlang external-term encoding of
`{item_id, attempt_number, attempt.decision}`. Deterministic reclamation audits use
the cleanup `operation_id` and exact action, target type, target ID, actor, and
evidence fingerprint; an existing row with any mismatch is a collision, not
success.

- [ ] **Step 8C.4: Add the fail-closed cleanup safety port**

Extend the callback and configuration contract:

```elixir
@callback cleanup_safety_locked(ForgeRepos.Repository.t(), DateTime.t()) ::
            :safe
            | {:blocked, :live_lease}
            | {:blocked, :claimable_operation}
            | {:blocked, :inconsistent_lease}
            | {:error, :unavailable}
```

`RepositoryWriteReconcilers.entries/0` now requires every configured module to
export both `reconcile_repository_locked/3` and `cleanup_safety_locked/2`; missing,
raising, exiting, throwing, or unknown callback results become
`{:error, :unavailable}`.

`GitWriteRecovery` owns inspection of `git_write_operations` and `MergeRecovery`
owns `pull_merge_operations`. For the target repository, any nonterminal row with
a future paired lease returns live-lease blocked; any nonterminal row with no lease
or an expired paired lease returns claimable-operation blocked; any one-sided lease
or terminal retained lease returns inconsistent-lease blocked. Only zero blocking
rows returns `:safe`. Tombstoned repositories are inspected only through this
safety callback; do not invoke normal reconciliation on a tombstone.

The import-domain preflight in Task 8D is independently fail-closed. Its only
nonterminal exception is the exact source chain of a `remote_quarantine` cleanup
operation; replacement-tombstone and unpublished-shadow cleanup have no import
exception. The exception contract is specified in Steps 8D.1 and 8D.5 and does not
weaken either repository-write safety callback.

- [ ] **Step 8C.5: Fence predecessor/successor adoption against cleanup intent**

In the existing `Persistence`/`Conflicts`/`RepositoryPublisher` transactions,
creation or adoption of a successor must lock the predecessor item first and
reject if its repository has a pending, blocked, or complete cleanup journal or a
non-null `storage_reclaimed_at`. Cleanup-intent creation locks the same predecessor
before inserting its journal. This makes adoption and cleanup intent mutually
exclusive rather than relying on a pre-transaction lookup.

Test both race winners: adoption first prevents intent; intent first prevents
successor creation/adoption. A complete journal remains a permanent adoption
barrier.

- [ ] **Step 8C.6: Run the PostgreSQL GREEN persistence suite**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/forge_imports/test/cleanup_operation_test.exs \
  apps/forge_imports/test/cleanup_recovery_migration_test.exs \
  apps/git_core/test/remote_test.exs \
  apps/forge_imports/test/import_persistence_test.exs \
  apps/forge_imports/test/import_persistence_concurrency_test.exs \
  apps/forge_imports/test/conflicts_test.exs \
  apps/forge_imports/test/repository_publication_test.exs \
  apps/forge_repos/test/git_writes_test.exs \
  apps/forge_repos/test/git_write_recovery_test.exs \
  apps/forge_pulls/test/merge_recovery_test.exs \
  --max-cases 1
```

Expected: the PostgreSQL suite proves migration up/down, schema checks, index
lifecycle, terminal-claim rejection, locking, exact evidence, safety-port failure,
audit/replay behavior, and the adoption-intent state-transition race matrix.

- [ ] **Step 8C.7: Commit durable cleanup intent**

```bash
git diff --check
git add \
  apps/fornacast/priv/repo/migrations/20260825000430_add_import_cleanup_recovery.exs \
  apps/fornacast/lib/fornacast/operation_lease.ex \
  apps/git_core/lib/git_core/remote.ex \
  apps/git_core/test/remote_test.exs \
  apps/forge_imports/lib/forge_imports/cleanup_operation.ex \
  apps/forge_imports/lib/forge_imports/persistence.ex \
  apps/forge_imports/lib/forge_imports/conflicts.ex \
  apps/forge_imports/lib/forge_imports/repository_publisher.ex \
  apps/forge_imports/test/cleanup_operation_test.exs \
  apps/forge_imports/test/cleanup_recovery_migration_test.exs \
  apps/forge_imports/test/import_persistence_test.exs \
  apps/forge_imports/test/import_persistence_concurrency_test.exs \
  apps/forge_imports/test/conflicts_test.exs \
  apps/forge_imports/test/repository_publication_test.exs \
  apps/forge_repos/lib/forge_repos/git_write_operation.ex \
  apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex \
  apps/forge_repos/lib/forge_repos/git_write_recovery.ex \
  apps/forge_repos/test/git_writes_test.exs \
  apps/forge_repos/test/git_write_recovery_test.exs \
  apps/forge_pulls/lib/forge_pulls/merge_operation.ex \
  apps/forge_pulls/lib/forge_pulls/merge_recovery.ex \
  apps/forge_pulls/test/merge_recovery_test.exs \
  config/config.exs
git commit -m "feat(import): persist repository cleanup intent"
```

#### Task 8D: Reconcile cleanup intent through anchored effects

**Commit:** `feat(import): reclaim repository storage safely`

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/repository_cleanup.ex`
- Create: `apps/forge_imports/lib/forge_imports/cleanup_reconciler.ex`
- Create: `apps/forge_imports/test/repository_cleanup_test.exs`
- Create: `apps/forge_imports/test/cleanup_reconciler_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports/recovery_supervisor.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_worker.ex`
- Modify: `apps/forge_imports/test/repository_worker_test.exs`
- Modify: `apps/fornacast/lib/fornacast/config.ex`
- Modify: `apps/git_core/lib/git_core/limits.ex`
- Modify: `apps/git_core/test/limits_test.exs`
- Modify: `apps/forge_repos/test/git_write_recovery_test.exs`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`
- Modify: `apps/git_transport/test/git_transport_test.exs`
- Modify: `apps/fornacast_web/test/git_http_auth_test.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Modify: `.env.example`
- Modify: `README.md`

- [ ] **Step 8D.1: Write RED eligibility, recovery, and scheduling tests**

In `repository_cleanup_test.exs` cover every true/false branch for all three kinds:

- replacement tombstone requires the exact old repository to be tombstoned and
  deleted, grace elapsed, `storage_reclaimed_at: nil`, item
  published/completed, current attempt completed, exact committed replacement
  marker and attempt fingerprint, exact ready new repository, and exact publication
  audit;
- unpublished shadow requires the canonical private importing repository,
  `write_version: 0`, `last_pushed_at: nil`, failed/canceled item, terminal run,
  compatible terminal current attempt, empty publication evidence, paired-null
  run/item leases, and no successor, adopter, or journal. Tombstone the shadow and
  create intent in one transaction; set eligibility to tombstone time plus grace;
- Remote quarantine requires item `state: :staging_git`,
  `cleanup_state: "cleanup_pending"`, due eligibility, paired-null or paired
  expired item lease, exact deterministic
  `GitCore.Remote.cleanup_evidence/1` matching the persisted requested/quarantine
  path and `mode/major_device/minor_device/inode`, and an operation keyed by the
  locked source item version. A future paired item lease reschedules just after
  expiry without creating/destructively attempting intent, and a one-sided item
  lease blocks.

For Remote quarantine, add paired RED cases proving the exact source-chain
exception and its boundary. The exact journal item may remain `:staging_git` with
`cleanup_pending`, its exact current attempt may remain `:running`, and its parent
run may be `:running`, `:cancel_requested`, `:awaiting_credential`, or any terminal
recovery state, provided journal/evidence/item/source lock version all match and
item/run leases are paired-null or expired. Change each fact independently and
assert blocking. Add any second nonterminal item, attempt, or run associated with
the repository and assert blocking even when the source chain itself is valid.
Pass the complete `CleanupOperation` to the verifier: prove a valid operation
passes without duplicating `operation_id` inside evidence, while a forged column
operation ID, wrong kind/repository/item/source version, operation borrowed from
another item, evidence with an extra operation-ID key, shadow mismatch, path
mismatch, basename-only slot hash, or four-field identity mismatch blocks.

Also cover grace at one second before/exactly at the boundary; nonterminal,
claimable, live, expired, and malformed leases in import/Git-write/merge domains;
successor-intent races; changed publication marker/path/identity/audit; root
replacement after observation; symlinks at every layer; special files; initial
anchored missing, missing after durable identity, forged absence, and
absence/base-path mismatch; mismatched relative/absolute joins; runtime config-root
drift before observation and before finalization; raw-SQL internally consistent
but wrong-root evidence; strict cache failure; limiter absence/crash; old-reader
blocking; claimable operations blocking;
crashes after journal creation, identity persistence, absence-proof persistence,
deletion, deletion followed by storage-root replacement, audit insertion, and
final CAS; two-pass replay; exact
`effect: "missing"` audit metadata for initial absence; no premature audit/marker;
audit collision; journal-less first discovery for every kind; due-journal replay
priority over a raw candidate; duplicate discovery/materialization races; raw
candidate disappearance; round-robin fairness; backoff; Remote retry restoration;
and later terminal settlement/unpublished cleanup.

In `cleanup_reconciler_test.exs` prove one operation per task/tick, independent task
supervisor capacity, hard runtime cancellation, due/keyset ordering, and
round-robin progress among the three kinds with no new same-kind work starving the
other kinds.

- [ ] **Step 8D.2: Run the cleanup RED tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test \
  apps/forge_imports/test/repository_cleanup_test.exs \
  apps/forge_imports/test/cleanup_reconciler_test.exs \
  --max-cases 1
```

Expected: FAIL because `RepositoryCleanup` and `CleanupReconciler` do not exist.

- [ ] **Step 8D.3: Add bounded configuration with a derived safety floor**

Add these exact settings:

```elixir
config :forge_imports,
  repository_cleanup_grace_seconds: 86_400,
  repository_cleanup_interval_ms: 30_000,
  repository_cleanup_deadline_ms: 60_000,
  repository_cleanup_lease_seconds: 120,
  repository_cleanup_backoff_min_seconds: 30,
  repository_cleanup_backoff_max_seconds: 21_600
```

`GitCore.Limits.minimum_repository_cleanup_grace_seconds/0` computes:

```elixir
div(
  GitCore.Limits.get(:remote_wall_time_ms) +
    GitCore.Limits.get(:remote_kill_escalation_ms) +
    GitCore.Limits.get(:remote_cleanup_wait_ms) +
    999,
  1_000
) + 1
```

With current hard limits this is `1816` seconds. Do not copy `1816` into runtime
validation. `Fornacast.Config` validates grace as an integer at least that derived
minimum and strictly greater than the three component durations; interval in
`1_000..300_000` ms; deletion deadline in `1_000..300_000` ms; lease seconds
strictly greater than ceiling(deadline/1000) and at most `3_600`; and backoff
`30 <= min <= max <= 21_600` seconds.

Read `FORNACAST_IMPORT_REPOSITORY_CLEANUP_GRACE_SECONDS` in `runtime.exs` with
default `86400` and fail startup on invalid input. Document that variable and the
same-UID/private-parent/single-node-exclusive-volume assumptions in
`.env.example` and `README.md`. VM restart recovery assumes one BEAM node owns the
repository volume exclusively.

- [ ] **Step 8D.4: Add a dedicated cleanup scheduler**

`RecoverySupervisor` starts two different `Task.Supervisor` children:
`ForgeImports.TaskSupervisor` remains `max_children: 1` for the existing import
scan, and new `ForgeImports.CleanupTaskSupervisor` is `max_children: 1` solely for
`CleanupReconciler`. Run the two reconcilers independently; neither crash nor a
long import scan consumes the other's slot.

Each cleanup tick selects at most one operation, starts at the kind after the last
attempted kind, and scans the three kinds round-robin. For each visited kind:

1. Query the oldest existing due `cleanup_pending` journal first, requiring
   `eligible_at <= now`, `next_attempt_at <= now`, and no live lease, ordered by
   `next_attempt_at, eligible_at, id`. If found, select it and do not inspect raw
   sources of that kind.
2. If no due journal exists, query exactly one raw source candidate that has no
   journal for its current `kind/source_lock_version`:
   - Remote quarantine: join the exact shadow and select `RepositoryItem` rows
     with `state: :staging_git`, `cleanup_state: "cleanup_pending"`,
     `cleanup_eligible_at <= now`, and the permitted lease shape; order by
     `cleanup_eligible_at, item.id`.
   - unpublished shadow: join the canonical importing private shadow, terminal
     item/run/current-attempt facts, empty publication evidence, zero write
     version/no last push, paired-null leases, and no successor/adopter; order by
     `COALESCE(item.cleanup_eligible_at, item.updated_at), item.id`.
   - replacement tombstone: join a tombstoned unreclaimed repository with
     `deleted_at <= now - grace` to the exact published/completed item, completed
     current attempt, committed replacement marker, ready successor, and audit;
     order by `repository.deleted_at, repository.id`.
3. The raw query uses `NOT EXISTS` on
   `repository_item_id/kind/source_lock_version` across pending, blocked, and
   complete journals. The unique index remains the race authority. After acquiring
   cleanup then writer permits, lock/revalidate the source and insert or load its
   deterministic journal. Process it in the same tick only if it is due.

At most one filesystem effect occurs per task/tick. An existing due journal always
wins over a new raw candidate of the same kind. If the raw row disappears or fails
CAS after selection, perform no write/effect and end the tick. Advance the
round-robin cursor after selection even when safety blocks, materialization loses a
race, the raw candidate disappears, or the new journal is not due. The task runtime
and anchored deletion share the configured hard deadline; continually arriving
same-kind work cannot starve the other kinds.

- [ ] **Step 8D.5: Materialize and claim exact cleanup intent**

Candidate/journal discovery in Step 8D.4 is read-only. After it yields a
repository ID, first acquire the exclusive read-cleanup permit and then the
existing writer permit. Only under both permits enter SQL and re-evaluate every
eligibility fact listed in Step 8D.1. Lock repository rows by ID ascending, then
import runs, repository items, current attempts, and cleanup journal. For a raw
unpublished shadow, the tombstone and intent insert are one transaction. For raw
replacement and Remote candidates, insert or load the deterministic journal using
the source item lock version; `NOT EXISTS` plus the unique index prevents
duplicates. A vanished/drifted raw candidate is a no-op, not an error. Use
`OperationLease.claim(CleanupOperation, id, owner, now, lease_seconds,
allowed_states: [:cleanup_pending])`.

Before any effect, `RepositoryCleanup.import_safety_locked/2` rejects associated
nonterminal or claimable import work, live/malformed import leases,
successors/adopters, and drifted journal/evidence/source facts. It permits exactly
one exception, and only when `operation.kind == :remote_quarantine`:

```elixir
item.id == operation.repository_item_id and
  item.lock_version == operation.source_lock_version and
  item.state == :staging_git and
  item.cleanup_state == "cleanup_pending" and
  exact_remote_evidence?(operation, item, shadow) and
  paired_null_or_expired?(item.lease_owner, item.lease_expires_at, now) and
  attempt.repository_item_id == item.id and
  attempt.attempt_number == item.attempt_count and
  attempt.state == :running and
  run.id == item.import_run_id and
  run.state in [
    :running,
    :cancel_requested,
    :awaiting_credential,
    :completed,
    :completed_with_warnings,
    :canceled,
    :failed
  ] and
  paired_null_or_expired?(run.lease_owner, run.lease_expires_at, now)
```

Define the verifier with the complete authoritative context:

```elixir
@spec exact_remote_evidence?(
        CleanupOperation.t(),
        RepositoryItem.t(),
        ForgeRepos.Repository.t()
      ) :: boolean()
defp exact_remote_evidence?(
       %CleanupOperation{} = operation,
       %RepositoryItem{} = item,
       %ForgeRepos.Repository{} = shadow
     )
```

It requires `operation.kind == :remote_quarantine`, exact operation
repository/item/source-lock columns, and
`operation.operation_id ==
deterministic_cleanup_operation_id(:remote_quarantine, shadow.id, item.id,
operation.source_lock_version)`. Then compare operation evidence with the locked
shadow identity/generation/canonical path, persisted `storage_root/relative_path`,
the item's requested/quarantine path and narrow cleanup evidence, and exact
`mode/major_device/minor_device/inode`. Recompute all Remote sibling/join
relationships from the persisted base and require
`quarantine_path == GitCore.Remote.cleanup_slot_path(requested_path)`. The
`operation_id` column is authoritative and is not duplicated in evidence; an
`operation_id` evidence key violates the exact-key validator. A live or one-sided
source item/run lease, mismatched context/evidence, non-current or non-running
source attempt, any other source state, or any second nonterminal
item/attempt/run for the repository blocks. No exception exists for a
successor/adopter or for replacement/unpublished cleanup.

Before the kind-specific safety check, require the live canonical
`Fornacast.Config.repo_storage_root()` to equal immutable
`operation.evidence["storage_root"]` byte-for-byte. Revalidate canonical
`relative_path` segments and every per-kind equality from Task 8C, then derive
`relative_segments = String.split(relative_path, "/", trim: false)`. Any config
drift, empty/dot/dotdot/backslash/NUL segment, absolute relative path, reconstructed
path mismatch, Remote sibling mismatch, or Remote helper mismatch moves the row to
`cleanup_blocked` before cache or filesystem access. Raw-SQL-forged root/path and
basename-only slot evidence therefore fail here even if structurally valid in the
database. The database proves internal persisted relationships; this application
check supplies the external live-config and exact-hash facts.

The same preflight rejects any nonterminal Git-write/merge operation and calls both
`cleanup_safety_locked/2` ports while the SQL rows are locked. A claimable
Git/merge operation is a slow retry, never permission to delete.

Outside SQL, acquire permits in this exact order:

```text
GitCore.RepositoryReadLimiter.acquire_cleanup(repository_id, deadline)
GitCore.RepositoryWriteLimiter.acquire(repository_id, deadline)
SQL verification/claim transaction
anchored filesystem effect
SQL finalization transaction
release writer permit
release cleanup permit
```

Readers never acquire the writer limiter, and ordinary writers never acquire the
read limiter, so this ordering introduces no cycle.

- [ ] **Step 8D.6: Execute and replay the anchored effect**

The effect state machine is:

1. The journal exists and is leased.
2. Using only persisted `storage_root` and segments derived from persisted
   `relative_path` after the live-config check, call
   `GitCore.contained_tree_identity/3` under both permits. On
   `{:present, %{root: root_identity, target: target_identity}}`, persist exact
   `root_identity`, `anchored_identity = target_identity`, and
   `effect_started_at` in one lease-owned transaction before any destructive call.
   Remote quarantine first obtains this full proof, requires `target_identity` to
   equal its existing `mode/major_device/minor_device/inode` evidence
   field-for-field, then persists both identities. On
   `{:missing, root_identity}`, persist exact
   `anchored_absence` with that canonical root companion plus
   `effect_started_at` and `effect_finished_at` in one lease-owned transaction
   before finalization. A crash after that transaction replays by revalidating the
   immutable base/live root and requiring a second anchored
   `{:missing, root_identity}` with all four root fields unchanged.
3. For either outcome, call `GitCore.invalidate_repository_cache_strict/1`.
   Cache failure retains `cleanup_pending` and performs no deletion or
   finalization.
4. Only for present-proof work, call `GitCore.remove_contained_tree/4` with exact
   `%{root: persisted_root_identity, target: persisted_anchored_identity}`.
   Removal is never called from an absence proof, with target identity alone, or
   without both persisted identities. The returned removed proof must equal the
   input proof. Partial removal, timeout, or I/O error retains pending state and
   backoff; replay uses both persisted identities. After removed, or after replay
   safely returns `{:missing, current_root_identity}`, persist
   `effect_finished_at` only when all four `current_root_identity` fields equal
   the pre-delete persisted root identity. A different current root moves the
   journal to `cleanup_blocked`.
5. Finalize only one of two mutually exclusive proofs:
   `root_identity + anchored_identity +
   (matching removed proof | safely missing replay with the same root identity)`,
   or
   `anchored_absence + safely missing with the same root identity`. Re-lock and
   CAS-check the exact repository/item/journal fingerprint, require the live
   config root still equals persisted `storage_root`, and revalidate/derive the
   same persisted relative segments before committing. For Remote, call
   `cleanup_slot_path(requested_path)` again and require exact quarantine/relative
   equality before audit or completion.

For replacement/unpublished cleanup, the final transaction sets
`Repository.storage_reclaimed_at`, inserts or verifies the deterministic
`repository.storage_reclaimed` audit, and marks the journal complete. No marker or
audit is written before absence. If DB/audit finalization fails after deletion,
the next pass may finish from anchored missing only when the newly observed
current-root identity exactly equals the persisted pre-delete root. Root
replacement blocks and never writes the audit/reclaimed marker. An existing audit
with mismatched actor/action/target/metadata/operation ID blocks cleanup.

For Remote quarantine, finalization instead inserts or verifies
`github_import.quarantine_reclaimed`, clears only the narrow item cleanup evidence,
restores the canonical staged destination path, schedules an immediate retry, and
marks the journal complete. It does not set repository
`storage_reclaimed_at`. The existing worker later settles the terminal run; if the
shadow then qualifies, unpublished-shadow cleanup creates a separate journal.

Both deterministic cleanup audit actions record `"effect" => "missing"` only for
a validated initial `anchored_absence`. Identity-backed removal records
`"effect" => "removed"` even when crash replay proves the post-removal path
missing.

- [ ] **Step 8D.7: Apply exact retry policy**

Use these outcomes:

- live lease: set `next_attempt_at` just after expiry plus deterministic
  per-operation jitter; do not increment destructive `attempt_count`;
- limiter unavailable, DB unavailable, cache unavailable, delete timeout, or
  delete I/O error: increment `attempt_count` and use exponential
  `min(30 * 2^(attempt_count - 1), 21_600)` seconds;
- claimable Git/merge/import operation: retry after `30` seconds without deleting;
- evidence/path/identity/symlink/special-file/audit mismatch or malformed lease:
  `cleanup_blocked` with redacted classified `last_error`;
- anchored missing before an outcome exists: persist `anchored_absence` and both
  effect timestamps, then finalize only after the exact proof revalidates;
- anchored missing with a durable present proof: treat only as removal replay and
  require current root to equal persisted pre-delete root; anchored missing with
  durable absence: require the same root and revalidate immutable base path/live
  config. Any root or config/path mismatch is `cleanup_blocked`. Never recreate or
  rediscover the path.

- [ ] **Step 8D.8: Run the focused PostgreSQL cleanup and read/write race suites**

Run these commands serially:

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/git_core/test/anchored_remove_test.exs \
  apps/git_core/test/repository_read_limiter_test.exs \
  apps/git_core/test/limits_test.exs \
  apps/git_core/test/native_surface_test.exs \
  apps/git_core/test/repository_read_model_test.exs \
  apps/forge_repos/test/repository_read_handle_test.exs \
  apps/forge_repos/test/repository_read_callsite_audit_test.exs \
  apps/forge_repos/test/forge_repos_test.exs \
  apps/forge_pulls/test/forge_pulls_test.exs \
  apps/git_transport/test/git_transport_test.exs \
  apps/git_transport/test/test_dirty_io_native_test.exs \
  apps/fornacast_web/test/git_http_auth_test.exs \
  apps/fornacast_web/test/repository_controller_test.exs \
  apps/fornacast_web/test/repository_page_test.exs \
  --max-cases 1
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/forge_imports/test/cleanup_operation_test.exs \
  apps/forge_imports/test/cleanup_recovery_migration_test.exs \
  apps/forge_imports/test/repository_cleanup_test.exs \
  apps/forge_imports/test/cleanup_reconciler_test.exs \
  apps/forge_imports/test/repository_worker_test.exs \
  apps/forge_imports/test/repository_publication_test.exs \
  apps/forge_imports/test/import_persistence_test.exs \
  apps/forge_imports/test/import_persistence_concurrency_test.exs \
  apps/forge_imports/test/conflicts_test.exs \
  apps/forge_repos/test/repository_lifecycle_test.exs \
  apps/forge_repos/test/git_writes_test.exs \
  apps/forge_repos/test/git_write_recovery_test.exs \
  apps/forge_pulls/test/merge_recovery_test.exs \
  --max-cases 1
```

Expected: both PostgreSQL commands exit zero. The matrix proves migration up/down,
checks, indexes, OperationLease exclusion, row locking, all path/identity cases,
lease and limiter races, old-reader behavior, strict cache invalidation, crash
replay, audit exactness, cleanup state transitions, fairness/backoff, Remote
retry/terminal settlement, and no premature audit/reclaimed marker.

- [ ] **Step 8D.9: Run final scoped static verification**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix format --check-formatted
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix compile --warnings-as-errors
git diff --check
git diff --stat HEAD~3
git diff HEAD~3 -- \
  apps/git_core apps/git_transport apps/forge_repos apps/forge_pulls \
  apps/forge_imports apps/fornacast/lib/fornacast/config.ex \
  apps/fornacast/lib/fornacast/operation_lease.ex \
  apps/fornacast/priv/repo/migrations/20260825000430_add_import_cleanup_recovery.exs \
  apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex \
  apps/fornacast_web/test/git_http_auth_test.exs \
  apps/fornacast_web/test/repository_controller_test.exs \
  config .env.example README.md
```

Expected: format, warnings-as-errors, and diff checks pass. Do not run broad
unrelated suites. If an existing out-of-scope warning or failure appears, record
its exact command and output and stop without modifying unrelated files.

- [ ] **Step 8D.10: Commit cleanup orchestration**

```bash
git add \
  apps/forge_imports/lib/forge_imports/repository_cleanup.ex \
  apps/forge_imports/lib/forge_imports/cleanup_reconciler.ex \
  apps/forge_imports/lib/forge_imports/recovery_supervisor.ex \
  apps/forge_imports/lib/forge_imports/repository_worker.ex \
  apps/forge_imports/test/repository_cleanup_test.exs \
  apps/forge_imports/test/cleanup_reconciler_test.exs \
  apps/forge_imports/test/repository_worker_test.exs \
  apps/fornacast/lib/fornacast/config.ex \
  apps/git_core/lib/git_core/limits.ex \
  apps/git_core/test/limits_test.exs \
  apps/forge_repos/test/git_write_recovery_test.exs \
  apps/forge_pulls/test/merge_recovery_test.exs \
  apps/git_transport/test/git_transport_test.exs \
  apps/fornacast_web/test/git_http_auth_test.exs \
  config/config.exs config/runtime.exs config/test.exs \
  .env.example README.md
git commit -m "feat(import): reclaim repository storage safely"
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/repository_import_controller_test.exs apps/fornacast_web/test/organization_controller_test.exs apps/fornacast_web/test/import_html_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/repository_import_controller_test.exs apps/fornacast_web/test/organization_controller_test.exs apps/fornacast_web/test/import_html_test.exs apps/fornacast_web/test/repository_controller_test.exs --max-cases 1
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
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_import_integration_test.exs --max-cases 1
```

Expected: 0 failures.

- [ ] **Step 3: Run all focused PostgreSQL suites serially**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/git_core/test/remote_test.exs apps/forge_repos/test apps/forge_imports/test apps/fornacast_web/test/repository_import_controller_test.exs apps/fornacast_web/test/organization_controller_test.exs apps/fornacast_web/test/repository_controller_test.exs apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/graphql_test.exs apps/git_transport/test --max-cases 1
```

Expected: 0 failures.

- [ ] **Step 4: Run formatter and warnings-as-errors**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix format --check-formatted
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix compile --warnings-as-errors
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
