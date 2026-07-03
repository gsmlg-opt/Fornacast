# Fornacast

Yes. For **Fornacast**, I would choose **gitoxide / `gix` as the strategic default**, not libgit2 — but I would put a hard abstraction boundary around it and treat the first 2–3 months as a compatibility spike.

My decision:

> **Use `gix`/gitoxide for `git_core`. Do not make libgit2 the core engine unless you prioritize short-term delivery over a pure Rust, BEAM-friendly architecture.**

The reason is simple: with your constraint of **Elixir + Rust NIF**, libgit2 brings a C library into the BEAM native boundary. That undermines one of the main reasons to use Rust NIFs in the first place.

---

# 1. The core tradeoff

| Criterion                         |                                   gitoxide / `gix` |                                                  libgit2 / `git2-rs` |
| --------------------------------- | -------------------------------------------------: | -------------------------------------------------------------------: |
| Language                          |                                          Pure Rust |                                       C library behind Rust bindings |
| BEAM/NIF safety profile           |                                             Better |                           Worse because C is inside the NIF boundary |
| Maturity                          |                                              Lower |                                                               Higher |
| API stability                     |                                   Lower / evolving | Higher, though libgit2 v2.0 is expected to introduce ABI/API changes |
| Git behavior compatibility        |                            Improving, not complete |                               Mature, but still not identical to Git |
| Server-side Git transport         |                        Not a finished forge server |                                     Also not a complete forge server |
| Object DB / refs / tree walking   |                                             Strong |                                                               Strong |
| Diff                              |              Strong but still needs parity testing |                                                               Strong |
| Blame                             | Available, but performance/parity still needs care |                                                          More mature |
| Merge                             |     Developing; workflow orchestration still risky |                                                          More mature |
| Future SHA-256 / reftable posture |                                          Promising |         SHA-256 moving from experimental to supported in future v2.0 |
| Licensing                         |                                   MIT / Apache-2.0 |                                         GPLv2 with linking exception |
| Deployment complexity             |                   Cargo-only Rust dependency graph |                              Native C library build/linking concerns |
| Best fit for Fornacast            |                                          Long-term |                                                           Short-term |

`gix` describes itself as the top-level repository abstraction over gitoxide’s plumbing crates, and the project goal is a pure Rust Git implementation including transport, object database, references, CLI, and TUI. It explicitly positions itself as an eventual alternative to libgit2. ([Docs.rs][1])

libgit2 is much more mature today: it is a portable C implementation of Git core methods, designed as a re-entrant linkable library, and its own documentation says it is used in production by major systems including GitHub.com and Azure DevOps. ([libgit2][2])

But for **your architecture**, the decisive issue is not general maturity. It is **where the risk lives**.

With libgit2:

```text
Elixir
  → Rustler NIF
    → git2-rs
      → libgit2 C
        → native memory / ABI / C dependency surface
```

With gitoxide:

```text
Elixir
  → Rustler NIF
    → Rust gix/gitoxide crates
```

That is a cleaner failure model.

---

# 2. My recommendation

Use this shape:

```text
apps/git_core
  lib/git_core.ex
  native/fornacast_git_core/
    Cargo.toml
    src/lib.rs
    src/repository.rs
    src/object.rs
    src/refs.rs
    src/diff.rs
    src/blame.rs
    src/merge.rs
```

But do **not** expose gitoxide types directly to Elixir.

Expose a Fornacast-owned API:

```elixir
GitCore.open_repository(repo_path)
GitCore.list_refs(repo)
GitCore.resolve_revision(repo, rev)
GitCore.read_tree(repo, commit_oid, path)
GitCore.read_blob(repo, blob_oid)
GitCore.diff_commits(repo, old_oid, new_oid, opts)
GitCore.merge_base(repo, left_oid, right_oid)
GitCore.blame_file(repo, commit_oid, path, opts)
GitCore.create_commit(...)
GitCore.update_ref(...)
```

Then behind the boundary:

```rust
fornacast_git_core::backend::gix
```

Later, if you absolutely need a second backend:

```rust
fornacast_git_core::backend::libgit2
```

But the Elixir side must never know whether the backend is `gix`, libgit2, or a future in-house implementation.

---

# 3. Do not make the NIF too large

Your table says:

> `git_core`: Rustler NIF over gitoxide/libgit2: object DB, refs, diff, blame, merge

That is okay.

But I would **not** put these into `git_core` initially:

```text
upload-pack server
receive-pack server
full smart HTTP protocol
full SSH Git protocol
packfile negotiation server
repository mirroring protocol
partial clone server
promisor remote handling
```

Those belong in `git_transport`, even if they call lower-level Rust helpers.

Better split:

```text
git_core
  object database
  refs
  rev parsing
  tree walking
  blob reading
  commit graph
  diff
  merge-base
  blame
  low-level pack helpers

git_transport
  pkt-line
  protocol v0/v1/v2
  ls-refs
  fetch negotiation
  pack generation
  receive-pack command parsing
  quarantine area
  hook execution contract
  push-options
  sideband
  report-status
```

gitoxide has protocol and transport building blocks, including packet-line support, protocol v1/v2 handshake handling, fetch, push plumbing, and notes about upload-pack/receive-pack server plumbing, but I would not assume it gives you a complete Forgejo-grade server implementation without a spike. ([GitHub][3])

---

# 4. Why I would not choose libgit2 as the core

libgit2 is attractive because it gives you a lot immediately:

```text
repository open/init
object lookup
refs
revwalk
diff
merge
blame
status
index
checkout
remote fetch/push client behavior
```

The libgit2 README lists object parsing/editing, tree traversal, revision walking, index manipulation, reference management, config management, high-level repository management, thread safety, and many API calls. ([GitHub][4])

The Rust `git2` crate is also a serious option, but its own documentation says it is bindings to libgit2 and that the library is still “a work in progress” and may lack some bindings. ([Docs.rs][5])

The bigger concerns for Fornacast:

## 4.1 C inside the BEAM boundary

Rustler helps make Rust NIFs safer: it handles term encoding/decoding and catches Rust panics before they unwind into C. ([GitHub][6])

But if your Rust NIF calls libgit2, you are now relying on a native C library inside the VM process. A C memory-safety bug, ABI mismatch, allocator issue, or unexpected crash is no longer isolated. In a Git forge, the native layer will parse untrusted repositories, packfiles, paths, refs, object headers, commits, trees, tags, and diffs. That is exactly the kind of workload where I would prefer pure Rust.

## 4.2 The hardest parity problem is not solved by libgit2

The hardest part of Fornacast parity is not:

```text
read a blob
walk a tree
render a diff
find merge-base
```

The hardest part is:

```text
serve upload-pack correctly
serve receive-pack correctly
handle protocol v2
handle shallow fetches
handle partial clone later
handle push options
handle quarantine
run hooks safely
enforce branch protection during receive
generate correct sideband output
match Git client expectations
```

libgit2 does not magically give you a Forgejo-grade `git-upload-pack` / `git-receive-pack` server. It is a Git library, not a complete forge transport service.

## 4.3 libgit2 has its own future transition

libgit2’s changelog says v1.9.0 is expected to be the final v1.x lineage, and that v2.0 is expected to include API and ABI changes as SHA-256 support moves from experimental to supported. ([GitHub][7])

That is not a blocker, but it matters. If Fornacast starts now and plans multi-year parity work, choosing libgit2 means you should budget for a future native dependency transition.

---

# 5. Why I would choose gitoxide / `gix`

The strongest argument for gitoxide is not that it is more mature. It is not.

The strongest argument is that it matches your intended architecture:

```text
Elixir orchestration
BEAM supervision
Rust NIF for bounded native Git operations
clean-room implementation
future self-contained forge
```

gitoxide is licensed MIT or Apache-2.0, is pure Rust, and its stated goal is an idiomatic, fast, safe Rust implementation of Git. ([GitHub][8])

The `gix` crate gives you a central `Repository` abstraction, exposes lower-level plumbing crates, has a trust model for repository/config access, and provides a thread-safe mode for use cases requiring `Sync`. ([Docs.rs][1])

That matters for a long-running server.

A forge will constantly do:

```text
open repo
read refs
resolve revision
walk commits
read tree
read blob
compute diff
find merge base
render blame
generate archive
index code
compute repo statistics
```

Those are good fits for Rust.

---

# 6. Where gitoxide is risky

Choosing gitoxide means accepting real integration risk.

The gitoxide docs explicitly warn that feature discovery can be hard and point users to the crate-status document to understand implemented and planned features. ([Docs.rs][9])

The status document lists already-supported workflows such as clone, fetch, `ls-refs`, commit, low-level ref/object/index mutation, status, blob/tree diffing, merge-base, revision parsing, and commit description. It also lists important workflows that still need plumbing or orchestration, including merge/cherry-pick/revert, rebase, and push/self-contained clone/fetch over file and SSH. ([GitHub][3])

The `gix` docs also note that `git2` performs strict hash verification and strict object creation by default, while gitoxide currently does not have those checks. ([Docs.rs][1])

That last point is very important for a forge. Fornacast must not silently accept corrupt or malicious object data. If you choose gitoxide, object validation becomes part of your acceptance criteria.

---

# 7. Recommended decision

For Fornacast:

## Choose gitoxide / `gix` if the project goal is:

```text
clean-room
pure Rust native layer
long-term self-contained Git forge
lower C/FFI risk
future-focused architecture
deep control over transport and storage
```

## Choose libgit2 if the project goal is:

```text
ship a usable Git UI faster
lean on mature APIs
accept C native dependency risk
accept libgit2 behavior as the practical compatibility baseline
possibly move faster on diff/blame/merge
```

Because you said **full parity** and **Elixir + Rust NIF**, my choice is:

```text
Primary backend: gitoxide / gix
Secondary role for libgit2: test/reference experiments only, not production core
External Git CLI: compatibility oracle in CI, not production dependency
```

---

# 8. Revised workload estimate for `git_core`

Your `6–9 months` estimate is plausible only if `git_core` is scoped to repository primitives.

I would split it like this:

| Capability                                     | Backend                   |     Effort |
| ---------------------------------------------- | ------------------------- | ---------: |
| NIF scaffolding, resource handles, error model | Rustler                   |  3–5 weeks |
| Repository open/init/bare detection            | `gix`                     |  2–3 weeks |
| Object lookup: commit/tree/blob/tag            | `gix`                     |  3–5 weeks |
| Ref listing/update/locking model               | `gix` + Fornacast policy  |  4–8 weeks |
| Revision parsing                               | `gix`                     |  3–5 weeks |
| Tree walking/file browser support              | `gix`                     |  3–5 weeks |
| Blob streaming/chunked reads                   | `gix`                     |  3–6 weeks |
| Diff between commits/trees                     | `gix-diff`/`gix`          | 6–10 weeks |
| Merge-base/compare view                        | `gix`                     |  3–5 weeks |
| Blame                                          | `gix-blame`, with caveats | 6–12 weeks |
| Merge analysis for PRs                         | `gix`/custom              | 8–16 weeks |
| Archive generation                             | `gix-archive` or custom   |  3–6 weeks |
| Integrity validation layer                     | custom + `gix`            | 6–12 weeks |
| Compatibility test suite                       | Git CLI oracle            | continuous |

So I would estimate:

```text
git_core read path:          4–6 months
git_core PR/diff/blame path: 6–9 months
git_core write/merge path:   9–15 months
```

The full `git_core` you described is closer to:

```text
9–15 months for one senior engineer
5–8 months for two strong engineers
```

The reason is not Rust syntax. It is Git behavior compatibility.

---

# 9. The acceptance test suite matters more than the backend

Before implementing too much, build this test harness:

```text
fornacast_git_compat/
  fixtures/
    empty_repo
    linear_history
    merge_commit
    criss_cross_merge
    huge_file
    binary_file
    unicode_paths
    weird_ref_names
    tags_annotated_lightweight
    submodules
    shallow_repo
    many_branches
    many_tags
    large_pack
    rename_heavy_history
    conflict_cases
    malicious_paths
    corrupt_objects
```

Each test should compare Fornacast behavior against canonical Git behavior.

Examples:

```bash
git rev-parse HEAD
git ls-tree -r HEAD
git cat-file -p <oid>
git diff <a> <b>
git merge-base <a> <b>
git blame <path>
git pack-objects
git fsck
```

For transport:

```bash
git ls-remote ssh://alice@localhost:2222/org/repo.git
git clone ssh://alice@localhost:2222/org/repo.git
git fetch --depth=1
git push origin main
git push origin :old-branch
git push --force-with-lease
GIT_PROTOCOL=version=2 git ls-remote ...
```

Your backend decision should pass through this gate:

```text
Can gix pass enough of our Git compatibility suite within 8–10 weeks?
```

If yes: continue with gix.

If no: either narrow v1 or introduce a second backend.

---

# 10. NIF design rules

Do not expose one giant NIF call like:

```elixir
GitCore.do_everything(repo_path, command, args)
```

Expose small, typed operations.

Good:

```elixir
GitCore.refs(repo)
GitCore.resolve(repo, "main")
GitCore.tree(repo, commit_oid, path)
GitCore.blob(repo, blob_oid, offset: 0, limit: 65_536)
GitCore.diff(repo, base_oid, head_oid, context: 3)
GitCore.merge_base(repo, left_oid, right_oid)
```

Bad:

```elixir
GitCore.git(repo, "diff main..feature --stat")
```

Also, any NIF operation that may take more than roughly 1 ms should use Rustler dirty schedulers. Rustler’s docs recommend using the `schedule` flag for functions that may take more than about 1 ms, with `DirtyCpu` for CPU-heavy work and `DirtyIo` for I/O-heavy work. ([Docs.rs][10])

Practical classification:

| Operation             | Scheduler                                    |
| --------------------- | -------------------------------------------- |
| OID parsing           | normal                                       |
| Refname validation    | normal                                       |
| Small metadata lookup | normal                                       |
| Tree walk             | DirtyIo or DirtyCpu depending implementation |
| Blob read             | DirtyIo                                      |
| Diff                  | DirtyCpu                                     |
| Blame                 | DirtyCpu                                     |
| Merge simulation      | DirtyCpu                                     |
| Pack generation       | DirtyCpu / not ideal as direct NIF           |
| Receive-pack          | avoid as one long NIF call                   |

For streaming operations, prefer this pattern:

```elixir
GitCore.open_blob(repo, oid)
GitCore.read_blob_chunk(handle, offset, size)
GitCore.close(handle)
```

not:

```elixir
GitCore.read_entire_blob(repo, oid)
```

For pack services, prefer a Rust resource that owns a state machine and is driven in chunks by Elixir processes.

---

# 11. Recommended `git_core` backend abstraction

In Elixir:

```elixir
defmodule Fornacast.GitCore do
  @callback open_bare(Path.t()) :: {:ok, repo()} | {:error, term()}
  @callback list_refs(repo()) :: {:ok, [ref()]} | {:error, term()}
  @callback resolve(repo(), String.t()) :: {:ok, oid()} | {:error, term()}
  @callback read_tree(repo(), oid(), Path.t()) :: {:ok, tree()} | {:error, term()}
  @callback read_blob(repo(), oid(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback diff(repo(), oid(), oid(), keyword()) :: {:ok, diff()} | {:error, term()}
  @callback merge_base(repo(), oid(), oid()) :: {:ok, oid()} | {:error, term()}
end
```

Then:

```elixir
defmodule Fornacast.GitCore.NativeGix do
  @behaviour Fornacast.GitCore
end
```

Rust:

```rust
mod gix_backend;
mod types;
mod errors;
mod refs;
mod objects;
mod diff;
mod blame;
mod merge;

#[rustler::nif(schedule = "DirtyIo")]
fn open_bare(path: String) -> NifResult<ResourceArc<RepoHandle>> {
    gix_backend::open_bare(path)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn diff_commits(repo: ResourceArc<RepoHandle>, old: String, new: String, opts: DiffOpts)
    -> NifResult<DiffResult>
{
    gix_backend::diff_commits(repo, old, new, opts)
}
```

Do not let `gix::Repository` leak into Elixir semantics.

---

# 12. Revised umbrella decomposition

I would adjust your umbrella slightly:

| App              | Responsibility                                                                    | Backend choice                             |
| ---------------- | --------------------------------------------------------------------------------- | ------------------------------------------ |
| `git_core`       | Object DB, refs, tree/blob/commit APIs, diff, blame, merge-base                   | `gix` NIF                                  |
| `git_pack`       | Packfile reading/writing, object validation, quarantine, fsck-like checks         | `gix` + custom Rust                        |
| `git_transport`  | Smart HTTP/SSH Git protocol, pkt-line, sideband, protocol v2, upload/receive-pack | Elixir orchestration + Rust state machines |
| `forge_repos`    | Repo lifecycle, storage routing, hooks, LFS, mirrors                              | Elixir                                     |
| `forge_accounts` | Users, orgs, teams, permissions, tokens, OAuth                                    | Elixir                                     |
| `forge_collab`   | Issues, PRs, reviews, labels, milestones, notifications                           | Elixir                                     |
| `forge_api`      | Gitea/Forgejo-compatible API                                                      | Elixir                                     |
| `forge_web`      | Phoenix/LiveView UI                                                               | Elixir                                     |
| `forge_ci`       | Actions-compatible orchestration                                                  | Elixir + workers                           |
| `forge_packages` | Package registries                                                                | Mostly Elixir                              |
| `forge_fed`      | Federation                                                                        | Elixir                                     |

I would separate `git_pack` from `git_core` because packfiles and receive-side validation are security-critical enough to deserve their own test matrix.

---

# 13. Transport warning

Your proposed `git_transport` says:

> Smart HTTP v2 protocol + `:ssh` daemon serving upload/receive-pack — 3–4 months

With no external Git executable, I think that is too low.

I would estimate:

```text
read-only upload-pack over SSH/HTTP: 4–6 months
push receive-pack MVP:              6–9 months
forge-grade receive-pack:           9–15 months
protocol v2 + shallow + push opts:  12–18 months
```

The receive side is especially hard because you need:

```text
quarantine area
object validation
ref transaction semantics
atomic pushes
report-status
sideband progress
push-options
branch deletion
forced update detection
hook contract
reference lock handling
permission checks
branch protection
LFS pointer policy
audit events
post-receive event fanout
```

gitoxide has useful protocol, transport, and packet-line pieces, but its own status notes still track server accept support and upload-pack/receive-pack server plumbing as part of the protocol/transport work. ([GitHub][3])

So: use `gix`, but budget transport as a serious product area, not a wrapper.

---

# 14. Final decision memo

## Decision

Use **gitoxide / `gix`** as Fornacast’s primary Git engine.

## Rationale

It is pure Rust, fits Rustler better, avoids embedding a C Git library into the BEAM VM, aligns with a long-term clean-room Fornacast architecture, and gives you more control over future Git transport/server behavior.

## Caveat

Do not assume `gix` gives you full Git server parity today. Build a compatibility harness immediately. Treat Git CLI behavior as the oracle. Keep the Fornacast API independent of `gix` so you can swap or supplement the backend later.

## Rejected default

Do not choose libgit2 as the default production NIF backend unless you decide that short-term feature maturity is more important than pure Rust isolation and long-term maintainability.

## Best practical path

```text
Phase 1: gix for read-only repository operations
Phase 2: gix for diff, compare, merge-base, blame
Phase 3: gix/custom Rust for receive-side validation and pack helpers
Phase 4: Elixir + Rust state machines for upload-pack/receive-pack
Phase 5: only introduce libgit2 if a specific compatibility gap blocks progress
```

So my answer is:

> **Choose gitoxide/gix, but architect as if you may need to replace parts of it. Use tests, not confidence, as the compatibility contract.**

[1]: https://docs.rs/gix "gix - Rust"
[2]: https://libgit2.org/ "libgit2"
[3]: https://github.com/GitoxideLabs/gitoxide/blob/main/crate-status.md "gitoxide/crate-status.md at main · GitoxideLabs/gitoxide · GitHub"
[4]: https://github.com/libgit2/libgit2 "GitHub - libgit2/libgit2: A cross-platform, linkable library implementation of Git that you can use in your application. · GitHub"
[5]: https://docs.rs/git2 "git2 - Rust"
[6]: https://github.com/rusterlium/rustler "GitHub - rusterlium/rustler: Safe Rust bridge for creating Erlang NIF functions · GitHub"
[7]: https://github.com/libgit2/libgit2/releases "Releases · libgit2/libgit2 · GitHub"
[8]: https://github.com/gitoxidelabs/gitoxide "GitHub - GitoxideLabs/gitoxide: An idiomatic, lean, fast & safe pure Rust implementation of Git · GitHub"
[9]: https://docs.rs/crate/gitoxide/latest "gitoxide 0.55.0 - Docs.rs"
[10]: https://docs.rs/rustler/latest/rustler/attr.nif.html "nif in rustler - Rust"
