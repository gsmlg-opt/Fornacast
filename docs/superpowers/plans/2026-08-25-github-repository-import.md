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

- Create: `apps/forge_repos/test/repository_write_fence_test.exs`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/forge_repos/git_write_recovery.ex`
- Modify: `apps/forge_repos/test/git_write_recovery_test.exs`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_recovery.ex`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`
- Modify: `apps/git_transport/test/receive_pack_fence_test.exs`

- [ ] **Step 1: Write the stale-writer regression**

Block one writer after it observes `%Repository{id: id, generation: 1}` but before it acquires the limiter. Tombstone that row and activate generation 2, then release the queued writer.

```elixir
assert {:error, {:unavailable, :stale_repository}} =
         ForgeRepos.with_write_fence(stale_repository, :receive_pack, fn _path, _remaining ->
           flunk("stale writer reached storage")
         end)
```

- [ ] **Step 2: Run and verify the stale writer reaches the old path**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_write_fence_test.exs --max-cases 1
```

Expected: FAIL because `with_write_fence/3` trusts the preloaded struct.

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

Use the reloaded row/path for reconciliation and the callback. Add `with_import_publication_fence/3`, which shares acquisition/reconciliation but returns `{:error, :destination_changed}` for an exact-target mismatch. Update Git-write, pull-merge, receive-pack, and content/ref callers to preserve their existing error mapping.

- [ ] **Step 4: Run every affected writer/recovery suite**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_write_fence_test.exs apps/forge_repos/test/git_write_recovery_test.exs apps/forge_pulls/test/merge_recovery_test.exs apps/git_transport/test/receive_pack_fence_test.exs --max-cases 1
```

Expected: all tests pass and no callback observes the tombstoned path.

- [ ] **Step 5: Commit fence hardening**

```bash
git add apps/forge_repos apps/forge_pulls apps/git_transport/test/receive_pack_fence_test.exs
git commit -m "fix(git): reject stale repository writers"
```

### Task 4: Implement supervised, credential-isolated Git mirrors

**Files:**

- Create: `apps/git_core/lib/git_core/remote.ex`
- Create: `apps/git_core/lib/git_core/remote/process.ex`
- Create: `apps/git_core/lib/git_core/remote/credential_cache.ex`
- Create: `apps/git_core/lib/git_core/remote/credential_reaper.ex`
- Create: `apps/git_core/lib/git_core/remote/host_policy.ex`
- Create: `apps/git_core/test/remote_test.exs`
- Modify: `apps/git_core/mix.exs`
- Modify: `apps/git_core/lib/git_core/application.ex`
- Modify: `apps/git_core/lib/git_core/limits.ex`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `mix.lock`

- [ ] **Step 1: Write process/credential/security tests around a fake git executable**

The fake records argv/environment, spawns a child, reads credential-helper input, emits bounded output, and simulates timeout/cancellation/corruption. Assert the PAT is absent from argv, environment, retained output, Git config, and staging files. Inject DNS results and reject every non-public IPv4/IPv6 class. Kill the owning BEAM worker and the recovery supervisor and prove the credential daemon/process group terminates; restart and prove orphan socket directories are reconciled.

```elixir
request = %GitCore.Remote.Request{
  provider: :github,
  owner: "octocat",
  repository: "hello-world",
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

Add `{:erlexec, "~> 2.3.4"}`. Use argument-list execution, process groups, monitor/link behavior, stdin, bounded stdout/stderr, `kill_group`, and configured SIGTERM-to-SIGKILL timeout. Do not invoke a shell.

Public structs:

```elixir
defmodule GitCore.Remote.Request do
  @enforce_keys [:provider, :owner, :repository, :destination, :default_branch]
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

Start an operation-local `git credential-cache--daemon <0700-dir>/credential.sock` under the same erlexec-managed OS process group as Git; approve `protocol=https`, `host=github.com`, verified username, and PAT over stdin. Link the owning BEAM process to the managed group so worker/supervisor/VM termination kills both daemon and Git descendants. Always send `credential-cache exit` and remove the socket directory in normal `after` cleanup. On `GitCore` startup, a reaper removes private operation socket directories whose registered owner/group no longer exists; socket files contain no credential bytes.

Clone with a sanitized config/environment, no prompt, no checkout/submodules/hooks/local optimization, `http.followRedirects=false`, disabled `file`/`ext` protocols, and a fixed `https://github.com/<owner>/<repo>.git` URL. `HostPolicy` resolves `github.com` and rejects every non-public address before Git starts. Remove `origin`, fetch config, and all refs except heads/tags. Validate physical bare storage, objects, limits, and default branch; set bare `HEAD`. Empty repositories remain valid. `refresh/3` performs one bounded authenticated refetch into an existing validated importing repository for the metadata-drift path.

- [ ] **Step 4: Run remote tests and existing GitCore smoke tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/git_core/test/remote_test.exs apps/git_core/test/git_core_test.exs --max-cases 1
```

Expected: all tests pass; cancellation kills the fake descendant.

- [ ] **Step 5: Commit the remote boundary**

```bash
git add apps/git_core config/config.exs config/test.exs mix.lock
git commit -m "feat(git): add supervised GitHub mirror"
```

### Task 5: Freeze explicit conflict decisions before start

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/conflicts.ex`
- Create: `apps/forge_imports/test/conflicts_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_item.ex`

- [ ] **Step 1: Write conflict/start tests**

Cover skip, rename, replace, apply-to-similar expansion, full-name confirmation, destination admin permission, complete fingerprint, no selected items, frozen attempt decisions, and drift returning to resolution.

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

Fingerprint exact repository ID, owner ID, storage path, generation, `updated_at`, and `last_pushed_at`. Rename revalidates owner/slug. Skip becomes a terminal item without a shadow. Starting requires at least one selected item, freezes a new attempt revision, and commits `github_import.conflicts_frozen` plus `github_import.started` audits with `awaiting_resolution -> ready -> running` before dispatch. If destination drift is detected later, transactionally close the frozen attempt with `destination_changed`, create the next attempt/decision revision, clear its unresolved decision fields, and return the item to `awaiting_resolution` without mutating the predecessor attempt.

- [ ] **Step 4: Run conflict and persistence tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/conflicts_test.exs apps/forge_imports/test/import_persistence_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit conflict decisions**

```bash
git add apps/forge_imports
git commit -m "feat(import): freeze repository conflicts"
```

### Task 6: Stage Git into an unreachable shadow repository

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/repository_stager.ex`
- Create: `apps/forge_imports/lib/forge_imports/repository_worker.ex`
- Create: `apps/forge_imports/test/repository_worker_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports/reconciler.ex`
- Modify: `apps/forge_imports/lib/forge_imports/recovery_supervisor.ex`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/mix.exs`
- Modify: `apps/forge_repos/lib/forge_repos.ex`

- [ ] **Step 1: Write worker phase and secret-custody tests**

Test transactional shadow insertion, generated internal slug, private visibility, intended generation, no `GitCore.init_bare`, saved/one-time callback checkout, `staging_git -> git_staged`, no production `ready_to_publish` transition before metadata, fully validated retry reuse, ambiguous staging rejection, failure cleanup intent, LFS/submodule warning entries, and zero public lookup/list visibility.

- [ ] **Step 2: Run the worker tests before implementation**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_worker_test.exs --max-cases 1
```

Expected: FAIL with missing stager/worker.

- [ ] **Step 3: Extend the existing reconciler and add the worker**

Add `{:git_core, in_umbrella: true}` to `apps/forge_imports/mix.exs`. Reuse M1's `ForgeImports.TaskSupervisor`. Extend the reconciler to claim runnable repository items as well as discovery runs, while preserving one bounded scan task. `ForgeRepos.create_import_shadow/4` inserts `lifecycle: :importing` with a generated valid internal slug and opaque path but performs no filesystem operation.

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

- [ ] **Step 4: Run worker, remote, and visibility tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_worker_test.exs apps/git_core/test/remote_test.exs apps/forge_repos/test/repository_lifecycle_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit staging**

```bash
git add apps/forge_imports apps/forge_repos/lib/forge_repos.ex
git commit -m "feat(import): stage hidden Git repositories"
```

### Task 7: Publish new and replacement repositories atomically

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/repository_publisher.ex`
- Create: `apps/forge_imports/test/repository_publication_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/forge_repos/collaborator.ex`

- [ ] **Step 1: Write publication and rollback tests**

Test new activation, exact-target replacement, collaborator copy, old/new audit IDs, partial active-index handoff, new numeric ID, URL stability, drift with immutable attempt rollover, audit failure rollback, database failure rollback, queued stale writer, metadata-gate refusal, and publication markers.

```elixir
assert {:ok, %{repository: published, replaced: old}} =
         ForgeImports.publish_repository(actor, item.id, request_metadata)

assert published.id == item.hidden_repository_id
refute published.id == old.id
assert published.slug == old.slug
assert published.generation == old.generation + 1
assert old.lifecycle == :tombstoned
```

- [ ] **Step 2: Run before publisher exists**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_publication_test.exs --max-cases 1
```

Expected: FAIL with missing publication API.

- [ ] **Step 3: Implement fenced publication transactions**

Both publication paths first require `ready_to_publish` plus durable terminal metadata-phase checkpoints; a merely `git_staged` item returns `{:error, :metadata_not_ready}`. For new publication: recheck actor/destination, lock shadow, recheck slug, set final owner/slug/settings and `ready`, then commit publication marker, `repository.imported` audit, and item state together.

For replacement: acquire the exact target's publication fence; reconcile pending Git writes/merges; lock target/shadow; compare the complete fingerprint; copy local collaborators; set old `tombstoned` and `deleted_at`; activate shadow under owner/slug with target generation + 1; record old/new IDs, `repository.replaced` audit, and item evidence in the same transaction. Return drift to `awaiting_resolution` without searching by slug.

- [ ] **Step 4: Run publication and fence tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_publication_test.exs apps/forge_repos/test/repository_write_fence_test.exs --max-cases 1
```

Expected: all tests pass; failed publication leaves the old repository ready.

- [ ] **Step 5: Commit publication**

```bash
git add apps/forge_imports apps/forge_repos
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

Test grace period, live/claimable import/write/merge leases, limiter acquisition, path containment, symlink rejection, missing directory idempotency, cache invalidation, crash after remove/before SQL proof, failed/canceled importing shadow abandonment, successor-adoption exclusion, and `storage_reclaimed_at` plus audit.

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
