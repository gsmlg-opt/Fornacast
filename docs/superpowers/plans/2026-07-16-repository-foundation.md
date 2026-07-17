# Repository Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Keep checkbox state in this file as work lands.

**Goal:** Deliver the approved read-only repository foundation: anonymous public browsing, one immutable Git snapshot per response, exact bounded repository data, DuskMoon Git presentation, repository search, safe raw/blob behavior, and verified desktop/mobile usability.

**Architecture:** Keep Phoenix controllers as the HTTP boundary, introduce a plain-data FornacastWeb.RepositoryPage orchestration boundary, and render only repository pages through targeted HEEx in FornacastWeb.RepositoryHTML. Keep Git traversal, limits, deadlines, error classification, and immutable caching inside GitCore and its DirtyIo Rust NIF. Only the concurrency limiters and disposable cache are supervised processes.

**Tech Stack:** Elixir 1.20, Phoenix 1.8 controllers and HEEx, ExUnit/Phoenix.ConnTest, PhoenixDuskmoon 9.8, MDEx, Tailwind/DuskmoonBundler, Rustler 0.38, gix 0.85, Rust unit tests, Bun assets, and Chrome DevTools browser verification.

**Approved specification:** docs/superpowers/specs/2026-07-16-repository-foundation-design.md

---

## Scope and execution guardrails

- This plan replaces only the repository tasks in docs/superpowers/plans/2026-07-06-forgejo-inspired-duskmoon-ui.md. Do not use the older repository plan.
- Browser repository reads are read-only. Do not add upload, edit, delete, commit, Watch, Star, Fork, Issues, Pull Requests, Actions, Packages, Projects, Releases, Wiki, or Activity.
- Do not add a database migration, repository-storage migration, LiveView conversion, or application-wide template rewrite.
- Preserve smart HTTP, SSH transport, namespace-aware owner/repository URLs, repository creation/import, and all existing GitCore transport entrypoints.
- Authorize before calling ForgeRepos.absolute_storage_path/1, GitCore, the cache, or any filesystem function.
- Use one resolved commit OID for every commit-derived region in a ref-backed response. The commit-detail URL SHA remains authoritative.
- Do not create a task or native call per tree row.
- Limit overrides used by tests may lower production bounds but may never raise them.
- Format only touched Elixir files. If an out-of-scope test fails, report it and stop instead of widening this slice.
- Every temporary dependency workaround must carry its upstream issue at the callsite:
  - duskmoon-dev/phoenix-duskmoon-ui#80 for clipboard behavior;
  - duskmoon-dev/phoenix-duskmoon-ui#82 for breadcrumb server links;
  - duskmoon-dev/phoenix-duskmoon-ui#83 for pagination server links.

## Decisions fixed by this plan

1. GitCore.Ref.target is the direct ref target OID. An annotated tag therefore retains its tag-object OID in ref results; only GitCore.Snapshot.oid is recursively peeled to a commit.
2. Legacy bare refs are represented by GitCore.RefSelector.kind == :legacy and resolve branch-first, then tag. Newly rendered links always use :branch or :tag with a canonical full name.
3. GitCore pagination returns an empty typed page plus exact totals for an out-of-range positive page. The controller maps it to repository-scoped 404. Page 1 remains valid for an empty collection.
4. Repository disk usage is the sum of logical file sizes returned by File.lstat/1 or native symlink_metadata. Symlinks are counted as entries and never followed.
5. Cache admission uses :erlang.external_size(value) for the 1 MiB value cutoff. Total cache accounting uses :erlang.external_size({key, value}) so keys count toward the 64 MiB bound.
6. Cache lookups happen before scan-limiter acquisition. Cache failure calls the same limited computation directly. Limiter failure fails closed as :scan_busy or :blob_busy.
7. A GitCore.Blob carries an opaque lease. The controller releases all leases in after blocks only after rendered or raw response bodies have been sent or discarded.
8. Language classification is case-insensitive by extension and uses this initial deterministic table:

| Language | Extensions or filename |
| --- | --- |
| Elixir | .ex, .exs |
| Erlang | .erl, .hrl |
| Rust | .rs |
| JavaScript | .js, .mjs, .cjs, .jsx |
| TypeScript | .ts, .tsx, .mts, .cts |
| CSS | .css |
| HTML | .html, .htm, .heex |
| Markdown | .md, .markdown |
| JSON | .json |
| TOML | .toml |
| YAML | .yml, .yaml |
| Shell | .sh, .bash, .zsh |
| Python | .py |
| Ruby | .rb |
| Go | .go |
| Java | .java |
| C | .c, .h |
| C++ | .cc, .cpp, .cxx, .hpp, .hh, .hxx |
| SQL | .sql |
| Dockerfile | Dockerfile and Dockerfile.* |

The fallback inspects the first shebang line only when the filename is not classified. elixir and escript map to Elixir; python and python3 to Python; node, deno, and bun to JavaScript; bash, sh, and zsh to Shell; ruby to Ruby. Remaining valid UTF-8 text is Other. Binary files and submodules are excluded.

9. The only public GitCore error kinds are :empty_repository, :ref_not_found, :commit_not_found, :path_not_found, :blob_too_large, :blob_busy, :invalid_repository, :storage_unavailable, :corrupt_repository, :scan_timeout, and :scan_busy. Empty repository is a 200 page state. Missing ref/commit/path is repository-scoped 404. Oversized complete raw is 413. Busy search/raw is 429 with Retry-After: 1. Busy or timed-out required summary/history/tree/diff and unavailable/corrupt storage are sanitized 503. Inline blob/README/language/disk follow their required-or-optional degradation rules; cooperative search/language bounds remain successful truncated results.

## File map

### Git read model

- Add apps/git_core/lib/git_core/read_model.ex
- Add apps/git_core/lib/git_core/scan_limiter.ex
- Add apps/git_core/lib/git_core/blob_limiter.ex
- Add apps/git_core/lib/git_core/cache.ex
- Add apps/git_core/native/fornacast_git_core/src/bounded_blob.rs
- Add apps/git_core/test/repository_read_model_test.exs
- Modify apps/git_core/lib/git_core.ex
- Modify apps/git_core/lib/git_core/native.ex
- Modify apps/git_core/lib/git_core/application.ex
- Modify apps/git_core/native/fornacast_git_core/src/lib.rs
- Modify apps/git_core/native/fornacast_git_core/Cargo.toml and Cargo.lock only when the bounded reader uses a public crate API that must be declared directly

### Authorization and URLs

- Add apps/forge_repos/test/access_test.exs
- Modify apps/forge_repos/lib/forge_repos.ex

### Repository web boundary

- Modify .formatter.exs
- Modify mix.exs
- Modify mix.lock only if root dependency resolution changes it
- Add apps/fornacast_web/lib/fornacast_web/repository_page.ex
- Add apps/fornacast_web/lib/fornacast_web/repository_markdown.ex
- Add apps/fornacast_web/lib/fornacast_web/repository_raw.ex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html.ex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html/code.html.heex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html/tree.html.heex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html/blob.html.heex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html/refs.html.heex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html/commits.html.heex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html/commit.html.heex
- Add apps/fornacast_web/lib/fornacast_web/controllers/repository_html/search.html.heex
- Add apps/fornacast_web/test/repository_controller_test.exs
- Add apps/fornacast_web/test/repository_page_test.exs
- Add apps/fornacast_web/test/repository_html_test.exs
- Modify apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex
- Modify apps/fornacast_web/lib/fornacast_web/router.ex
- Modify apps/fornacast_web/lib/fornacast_web/html.ex
- Modify apps/fornacast_web/assets/css/app.css
- Modify apps/fornacast_web/assets/js/app.js
- Modify apps/fornacast_web/test/fornacast_web_test.exs
- Modify config/dev.exs
- Add scripts/repository_qa_fixture.exs

## Task 1: Lock the repository authorization matrix

**Files:**

- Add: apps/forge_repos/test/access_test.exs
- Read only unless a characterization fails: apps/forge_repos/lib/fornacast/access.ex

- [x] **Step 1: Move repository access cases into the scoped test file**

Create fixture helpers for active and disabled users, one personal repository, one organization repository, organization owner/member records, and read/write/admin collaborator rows. Keep database reset logic local to the new file.

- [x] **Step 2: Assert the complete read/write/admin matrix**

Cover:

- anonymous public read and anonymous write denial;
- personal owner read/write/admin;
- organization owner read/write/admin;
- organization member read only;
- read collaborator read only;
- write collaborator read/write;
- admin collaborator read/write/admin;
- active site admin access;
- anonymous private denial;
- unrelated active-user private denial;
- disabled actors retain anonymous public read only, but are denied private, write, and admin access regardless of ownership, collaboration, or site role.

- [x] **Step 3: Run the characterization**

~~~sh
mix test apps/forge_repos/test/access_test.exs --trace
~~~

Expected: all cases pass against the existing centralized access module. If one fails, change only Fornacast.Access to match the approved matrix and rerun this file.

- [x] **Step 4: Commit the access contract**

~~~sh
git add apps/forge_repos/test/access_test.exs apps/forge_repos/lib/fornacast/access.ex
git commit -m "test(repos): lock repository access matrix"
~~~

## Task 2: Establish typed GitCore read contracts and errors

**Files:**

- Add: apps/git_core/lib/git_core/read_model.ex
- Add tests: apps/git_core/test/repository_read_model_test.exs
- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs

- [x] **Step 1: Add failing struct and typed-error tests**

Assert fixed fields, stable error kinds, and operation names. Cover missing repository, non-bare repository, missing ref, missing commit, missing path, and corrupt object data. Assert diagnostic detail is present for logs but never needed to determine kind.

Tag the grouped repository-read tests with :typed_errors, :prefix_blob, :limiter, :refs, :commits, :tree_history, :blobs, :diffs, :search, :analysis, or :cache so every scoped command in this plan selects an explicit group.

- [x] **Step 2: Define the public read-model types**

Move the existing Ref, Commit, TreeEntry, Blob, DiffFile, and CommitDiff modules out of GitCore into read_model.ex without changing their public module names. Extend them and add these types:

~~~elixir
defmodule GitCore.Error do
  @enforce_keys [:kind, :operation]
  defstruct [:kind, :operation, :detail]
end

defmodule GitCore.RefSelector do
  @enforce_keys [:kind, :full_name]
  defstruct [:kind, :full_name]
end

defmodule GitCore.RefSummary do
  @enforce_keys [:branch_count, :tag_count, :branches, :tags, :refs_truncated]
  defstruct [:branch_count, :tag_count, :branches, :tags, :refs_truncated]
end

defmodule GitCore.RefPage do
  @enforce_keys [:refs, :total, :page, :per_page, :total_pages]
  defstruct [:refs, :total, :page, :per_page, :total_pages]
end

defmodule GitCore.Snapshot do
  @enforce_keys [:kind, :ref, :oid]
  defstruct [:kind, :ref, :oid]
end

defmodule GitCore.CommitSummary do
  @enforce_keys [:count, :latest]
  defstruct [:count, :latest]
end

defmodule GitCore.CommitPage do
  @enforce_keys [:commits, :total, :page, :per_page, :total_pages]
  defstruct [:commits, :total, :page, :per_page, :total_pages]
end

defmodule GitCore.TreeHistoryEntry do
  @enforce_keys [:name, :kind, :mode, :oid, :latest_commit]
  defstruct [:name, :kind, :mode, :oid, :latest_commit]
end

defmodule GitCore.TreePage do
  @enforce_keys [:entries, :total_entries, :page, :per_page, :total_pages]
  defstruct [:entries, :total_entries, :page, :per_page, :total_pages]
end

defmodule GitCore.DiffLine do
  @enforce_keys [:type, :content]
  defstruct [:type, :old_line, :new_line, :content]
end

defmodule GitCore.SearchResult do
  @enforce_keys [:path]
  defstruct [:path, :line, :snippet]
end

defmodule GitCore.SearchResults do
  @enforce_keys [:scope, :results, :files_scanned, :bytes_scanned, :truncated_reasons]
  defstruct [:scope, :results, :files_scanned, :bytes_scanned, :truncated_reasons]
end

defmodule GitCore.LanguageStat do
  @enforce_keys [:language, :bytes]
  defstruct [:language, :bytes]
end

defmodule GitCore.RepositoryAnalysis do
  @enforce_keys [:languages, :total_bytes, :files_scanned, :bytes_scanned, :truncated]
  defstruct [:languages, :total_bytes, :files_scanned, :bytes_scanned, :truncated]
end
~~~

Extend GitCore.Ref with display_name. Extend GitCore.Blob with non_utf8 and lease. Extend GitCore.DiffFile with additions, deletions, truncated, and lines. Extend GitCore.CommitDiff with changed_files, additions, and deletions while retaining files, patch, and truncated.

- [x] **Step 3: Return tagged native errors**

Use a fixed native tuple shape:

~~~rust
type NativeError = (String, String);

fn native_error(kind: &'static str, detail: impl std::fmt::Display) -> NativeError {
    (kind.to_string(), detail.to_string())
}
~~~

Classify errors where context is known rather than parsing gix display strings later. Return only the approved kind strings. In Elixir, map those strings with explicit function clauses; never call String.to_atom/1.

- [x] **Step 4: Wrap every repository read with its operation**

Use a single helper that converts native tagged errors to:

~~~elixir
{:error, %GitCore.Error{kind: kind, operation: operation, detail: detail}}
~~~

Keep init_bare/1, pack_objects/2, receive_pack/3, and the successful legacy read return shapes compatible with existing Git transport callers.

- [x] **Step 5: Run typed and compatibility tests**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only typed_errors --trace
mix test apps/git_core/test/git_core_test.exs
mix test apps/git_transport/test/git_transport_test.exs
~~~

Expected: stable typed read failures and no successful transport regression.

- [x] **Step 6: Commit the read boundary**

~~~sh
git add apps/git_core/lib/git_core/read_model.ex apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): add typed repository read contracts"
~~~

## Task 3: Gate prefix-bounded blob decoding

This is a hard feasibility gate. Do not begin Tasks 4 through 16 until the Go condition passes.

**Files:**

- Add: apps/git_core/native/fornacast_git_core/src/bounded_blob.rs
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Modify only if a public API is used directly: apps/git_core/native/fornacast_git_core/Cargo.toml
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Build verified loose, packed-base, and packed-delta fixtures**

In Rust unit-test helpers, create multi-megabyte deterministic blobs. Keep one loose, repack one with delta compression disabled, and create two highly similar large objects for the delta case. Run git verify-pack -v from the fixture helper and fail setup unless the expected base or delta storage form is confirmed.

- [x] **Step 2: Add failing bounded-reader tests**

Use a 64 KiB prefix limit. For all three storage forms assert:

- header metadata reports the exact complete size before content allocation;
- returned data equals exactly the original prefix;
- returned length never exceeds the requested limit;
- truncated is true when size exceeds the limit;
- a limit at or above object size returns the complete body with truncated false;
- test instrumentation records no complete final-object buffer and no decoded object buffer larger than the requested prefix limit.

- [x] **Step 3: Implement the minimum public-API prototype**

Use gix header metadata for kind and size. Do not assume gix 0.85 has a public prefix stream. The bounded path must not call entry.object(), try_into_blob(), a repository lookup that fills a complete object buffer, private crate internals, or an external git cat-file process. Implement only against stable public gix, gix-odb, or gix-pack primitives.

- [x] **Step 4: Add an Elixir integration tag**

Route GitCore.read_blob/4 through the bounded prototype for immutable commit OIDs. Under an ExUnit prefix_blob tag, assert exact size, data, truncated, binary, and non_utf8 values for all three verified storage forms.

- [x] **Step 5: Run the gate**

~~~sh
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml prefix_blob -- --nocapture
mix test apps/git_core/test/repository_read_model_test.exs --only prefix_blob --trace
~~~

**Go condition:** both commands pass for loose, packed-base, and verified packed-delta blobs, and the implementation plus instrumentation proves bounded decoding rather than full materialization followed by slicing.

**Stop condition:** if packed-base or packed-delta decoding requires a complete final/base object buffer, non-public gix internals, a fork, or an external Git process, stop repository-foundation implementation. Report the exact failing storage form and request one design choice: change the dependency/version, build a dedicated bounded pack/delta decoder, or revise the contract. Do not retain the existing full-read-and-slice behavior.

- [x] **Step 6: Commit only after the Go condition passes**

~~~sh
git add apps/git_core/native/fornacast_git_core/src/bounded_blob.rs apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/native/fornacast_git_core/Cargo.toml apps/git_core/native/fornacast_git_core/Cargo.lock apps/git_core/lib/git_core.ex apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): prove bounded blob prefix reads"
~~~

## Task 4: Add scan and weighted blob limiters

**Files:**

- Add: apps/git_core/lib/git_core/scan_limiter.ex
- Add: apps/git_core/lib/git_core/blob_limiter.ex
- Modify: apps/git_core/lib/git_core/application.ex
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Add failing scan-limiter tests**

Start disposable limiter processes with lower capacities. Prove four production permits, FIFO waiter admission, a lower test wait timeout, :scan_busy on expiration, release in after, monitor cleanup when an owner dies, and fail-closed behavior when the limiter process is unavailable.

- [x] **Step 2: Implement the scan lease**

Expose:

~~~elixir
GitCore.ScanLimiter.with_permit(operation, fn -> result end, opts)
~~~

The GenServer owns the 250 ms waiter timer, monitors queued and granted owners, removes either state on DOWN, and replies with a unique lease reference. The public call waits indefinitely for that server-owned reply so a client timeout cannot leave a ghost waiter. The caller executes the function and releases in after. Production capacity is four. Test options may supply a different server and lower capacity or wait timeout.

- [x] **Step 3: Add failing weighted blob-limiter tests**

Prove both independent limits: at most eight leases and at most 128 MiB declared bytes. Cover a zero-byte raw body still consuming one read slot, queueing, a request heavier than remaining capacity, exact-weight release, owner death, idempotent release, 250 ms :blob_busy, and fail-closed process failure.

- [x] **Step 4: Implement opaque blob leases**

Expose:

~~~elixir
{:ok, lease} = GitCore.BlobLimiter.acquire(weight, opts)
:ok = GitCore.BlobLimiter.release(lease)
~~~

Reject a single weight above 128 MiB without allocation. Inline callers reserve 1_048_576 bytes. Complete callers reserve exact header size. Never release inside the native wrapper before the response owns or discards the body.

- [x] **Step 5: Supervise both processes**

Use a one_for_one child list:

~~~elixir
children = [
  GitCore.ScanLimiter,
  GitCore.BlobLimiter
]
~~~

- [x] **Step 6: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only limiter --trace
mix test apps/git_core/test/git_core_test.exs
git add apps/git_core/lib/git_core/scan_limiter.ex apps/git_core/lib/git_core/blob_limiter.ex apps/git_core/lib/git_core/application.ex apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): bound repository read concurrency"
~~~

## Task 5: Implement canonical refs and immutable snapshots

**Files:**

- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/bounded_blob.rs
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Add deterministic ref fixtures and failing tests**

Create more than 100 branch refs and more than 100 tags with Git plumbing. Include branch and tag with the same short name, refs containing slashes, an annotated tag, a nested annotated tag, and a tag targeting a non-commit object.

Assert exact counts, bytewise full-name ordering, first-100 samples, selected-ref inclusion outside the sample, refs_truncated, exact page totals, valid empty page 1, empty out-of-range pages, direct ref target OIDs, canonical resolution, recursive tag peeling, and legacy branch-first behavior.

- [x] **Step 2: Add the public ref APIs**

~~~elixir
GitCore.ref_summary(path, selected_ref: full_ref)
GitCore.ref_summary_for_route(path, route_segments)
GitCore.ref_page(path, kind, page, per_page: 100)
GitCore.resolve_snapshot(path, %GitCore.RefSelector{})
~~~

Clamp per_page to 100. The web boundary validates positive pages; GitCore still returns typed page metadata for every positive page.

- [x] **Step 3: Implement one bounded native ref scan**

For summary and page operations:

- accept only refs/heads/ and refs/tags/;
- retain exact branch and tag counts;
- sort by full ref-name bytes;
- derive display_name by removing the known prefix;
- retain at most the first 100 of each kind plus the selected ref;
- check the five-second monotonic deadline;
- run through ScanLimiter.

Keep list_refs/1 complete and independent for Git transport.

- [x] **Step 4: Resolve snapshots without probing trees**

Canonical selectors attempt only their exact full ref. Legacy selectors construct refs/heads/value first and refs/tags/value second. Peel annotated tags until a commit or failure. Return :ref_not_found for a missing ref, a cycle, or a final non-commit object.

- [x] **Step 5: Fold wildcard matching into the first bounded ref scan**

For source and raw wildcard routes, ref_summary_for_route/2 performs the request's first GitCore operation. In the same five-second, ScanLimiter-protected native ref scan, compute the exact summary and match route segments from longest to shortest against exact ref names. A refs/heads or refs/tags prefix fixes the declared kind. Legacy segments test every branch candidate before tag candidates. Return {ref_summary, typed_selector, untouched_repository_path} without peeling or returning an OID. Include the matched selected ref outside the first-100 sample when required. RepositoryPage then resolves that selector exactly once. Do not call read_tree while finding the split and do not run a second ref scan.

- [x] **Step 6: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only refs --trace
mix test apps/git_transport/test/git_transport_test.exs
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/bounded_blob.rs apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): add canonical repository snapshots"
~~~

## Task 6: Add exact deterministic commit summary and pages

**Files:**

- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Add a merge-DAG fixture**

Use git commit-tree and update-ref to build roots, two branches, a merge, and equal committer timestamps. Assert all-parent unique counting and deterministic OID tie ordering.

- [x] **Step 2: Add failing summary/page tests**

Cover exact total, latest tip metadata, 50-row cap, exact total_pages, valid empty page 1, out-of-range typed empty page, five-second timeout via a lower test deadline, scan busy, corrupt commits, and immutable-OID input.

- [x] **Step 3: Implement one shared commit walker**

Load the reachable graph with a visited OID set while checking the deadline. Build child counts, then emit child-before-parent topological order from a priority queue keyed by committer time descending and OID ascending. Use the same ordered graph for count, summary, pagination, and later tree attribution.

- [x] **Step 4: Expose the APIs**

~~~elixir
GitCore.commit_summary(path, snapshot_oid)
GitCore.commit_page(path, snapshot_oid, page, per_page: 50)
~~~

Clamp per_page to 50 and run both through ScanLimiter. Return :scan_timeout rather than partial exact totals.

- [x] **Step 5: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only commits --trace
mix test apps/git_core/test/git_core_test.exs
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): add exact commit pagination"
~~~

## Task 7: Add commit-aware bounded trees

**Files:**

- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Add failing tree-history tests**

Build a directory with more than 200 direct children. Change files beneath directories across multiple commits and a merge. Assert directories-first bytewise name ordering, exact totals/pages, 200-row cap, first-parent attribution, root comparison against an empty tree, directory descendant touches, current-path-only behavior after a rename, slash refs through their resolved OID, and out-of-range pages.

- [x] **Step 2: Prove one native history walk**

Add a test-only call log or native counter around read_tree_with_history. One page request must make one native call and one commit traversal, regardless of row count.

- [x] **Step 3: Implement page-first attribution**

Resolve the selected tree from snapshot_oid, list direct children, sort directories first, calculate exact page metadata, and retain only the requested 200 rows. Traverse commits once in the Task 6 order. For each unresolved current row, compare its OID and mode with the first parent at the same path; compare roots with absence. A directory tree OID change counts as a descendant touch. Stop when every retained row has metadata.

- [x] **Step 4: Expose and limit the API**

~~~elixir
GitCore.read_tree_with_history(path, snapshot_oid, tree_path, page, per_page: 200)
~~~

Use safe Git tree lookup, never filesystem path joining. Run through ScanLimiter with the five-second deadline.

- [x] **Step 5: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only tree_history --trace
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): add commit-aware tree pages"
~~~

## Task 8: Complete the blob and raw-read lifecycle

**Files:**

- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/bounded_blob.rs
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Add failing metadata and lease tests**

Cover inline reservation of exactly 1 MiB, metadata-before-allocation, complete read reservation by exact size, 100_000_000-byte rejection before allocation, invalid UTF-8, binary NUL detection, successful lease retention, explicit release, owner death, and :blob_busy.

- [x] **Step 2: Split native blob operations**

Add immutable-snapshot operations for:

- tree lookup and blob metadata;
- bounded prefix read by verified blob OID;
- complete read by verified blob OID.

Recheck the OID and declared size between metadata and body operations. Complete reads allocate only after the exact-size permit is granted.

- [x] **Step 3: Expose inline and complete APIs**

~~~elixir
GitCore.read_blob(path, snapshot_oid, blob_path, limit: 1_048_576)
GitCore.read_blob_complete(path, snapshot_oid, blob_path, limit: 100_000_000)
GitCore.release_blob(%GitCore.Blob{})
~~~

Clamp limits to their production maxima. Inline returns a prefix with 200-compatible truncated state. Complete returns either the entire body or :blob_too_large and never returns a truncated success.

- [x] **Step 4: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only blobs --trace
mix test apps/git_core/test/git_core_test.exs
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/bounded_blob.rs apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): enforce complete and bounded blob reads"
~~~

## Task 9: Produce structured bounded commit diffs

**Files:**

- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Add failing diff fixtures**

Cover added, modified, deleted, binary, root commit, context lines, multiple hunks, line numbers, more than 1,000 files, a retained payload beyond 200,000 bytes, and a lower deadline.

- [x] **Step 2: Assert exact and retained data separately**

Assert complete changed-file/addition/deletion totals even when only 1,000 sections or 200,000 source bytes are retained. Assert per-file truncation, global truncation, binary metadata without text lines, and one shared retained source budget from which both patch and structured lines are derived.

- [x] **Step 3: Replace delete-all/add-all output**

Use the public gix diff callbacks to obtain real hunks and line statistics. Disable rewrite detection and repository-configured external filters. Convert output directly to NativeDiffLine tuples carrying type, old line, new line, and content. Process one file at a time and retain no prior file bodies beyond the shared output material.

- [x] **Step 4: Preserve compatibility**

Continue populating CommitDiff.patch from the same retained source material and keep existing success callers working. Run the whole operation through ScanLimiter with the five-second deadline; return :scan_timeout if exact totals cannot finish.

- [x] **Step 5: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only diffs --trace
mix test apps/git_core/test/git_core_test.exs
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): return structured commit diffs"
~~~

## Task 10: Add deterministic repository search

**Files:**

- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [x] **Step 1: Add failing path-search tests**

Assert case-insensitive literal matching, bytewise path ordering, at most 100 results, the 10,000-file limit, two-second deadline, stable repeated results, and ordered truncated_reasons.

- [x] **Step 2: Add failing content-search tests**

Assert valid UTF-8 only, binary exclusion, blobs over 1 MiB skipped, at most one result per matching line, one-based line numbers, 240-character snippets, path-then-line ordering, 64 MiB eligible-byte bound, result bound, and combined reason display order:

~~~elixir
[:file_limit, :byte_limit, :deadline, :result_limit]
~~~

- [x] **Step 3: Implement one sorted snapshot traversal**

Walk only snapshot_oid. Sort paths before applying result caps. For content scope, inspect declared size before reading, skip sizes over 1 MiB, and scan line data without retaining unrelated blob content. Use Unicode lowercase comparison for the literal query. Check file, byte, result, and monotonic time bounds cooperatively.

- [x] **Step 4: Expose the API**

~~~elixir
GitCore.search_tree(path, snapshot_oid, query,
  scope: :path,
  file_limit: 10_000,
  byte_limit: 67_108_864,
  result_limit: 100,
  deadline_ms: 2_000
)
~~~

Normalize scope in Elixir, lower-only clamp every bound, run through ScanLimiter, and do not cache queries.

- [x] **Step 5: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only search --trace
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): add bounded repository search"
~~~

## Task 11: Add language and repository-size analysis

**Files:**

- Modify: apps/git_core/lib/git_core.ex
- Modify: apps/git_core/lib/git_core/native.ex
- Modify: apps/git_core/native/fornacast_git_core/src/bounded_blob.rs
- Modify: apps/git_core/native/fornacast_git_core/src/lib.rs
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [ ] **Step 1: Add classification tests**

Create one file for every extension group, Dockerfile variants, every shebang group, unknown text, invalid UTF-8, NUL binary, and a submodule. Assert byte-weighted totals, alphabetical tie ordering, binary/submodule exclusion, and Other.

- [ ] **Step 2: Add cooperative-bound tests**

Lower file, byte, and deadline values. Assert partial results include files_scanned and bytes_scanned, truncated is true, and complete percentages are not inferred from partial data.

- [ ] **Step 3: Implement language analysis**

Traverse snapshot_oid deterministically through ScanLimiter. Apply the fixed table above. Stream eligible content through bounded buffers to validate UTF-8 and binary status; retain no file body. Stop at 100,000 files, 536_870_912 eligible bytes, or two seconds. Return a partial success on a cooperative bound and a typed failure only for unexpected read errors.

- [ ] **Step 4: Add safe disk-size tests**

Create files, nested directories, and a symlink pointing outside the bare repository. Assert logical file-byte sum, no symlink traversal, a lower two-second timeout, and changed size after git gc or repack.

- [ ] **Step 5: Implement uncached disk usage**

Walk the canonical trusted repository root using symlink_metadata. Do not follow symlink directories. Check the monotonic deadline between entries. Run through ScanLimiter and return the byte integer. Never cache this operation.

- [ ] **Step 6: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only analysis --trace
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): analyze repository languages and size"
~~~

## Task 12: Add disposable immutable GitCore caching

**Files:**

- Add: apps/git_core/lib/git_core/cache.ex
- Modify: apps/git_core/lib/git_core/application.ex
- Modify: apps/git_core/lib/git_core.ex
- Add tests: apps/git_core/test/repository_read_model_test.exs

- [ ] **Step 1: Add failing cache-unit tests**

Use a disposable process and an injected monotonic clock. Cover hit/miss, storage-path isolation, every semantic key argument, 512-entry LRU, 64 MiB total accounting, value-over-1-MiB bypass, 15-minute idle expiration, access refreshing LRU/idle state, process/table failure, and concurrent callers.

- [ ] **Step 2: Implement the supervised ETS cache**

Serialize get/put through a GenServer so access order is exact. Store key, value, key-and-value byte size, last-access sequence, and last-access monotonic time. Remove expired entries before every lookup and admission, and evict least-recently-accessed entries until both limits hold.

Add GitCore.Cache after ScanLimiter and BlobLimiter in GitCore.Application's one_for_one child list.

- [ ] **Step 3: Expose a fallback-safe fetch**

~~~elixir
GitCore.Cache.fetch(key, fn -> limited_computation end)
~~~

Treat a lookup exception/exit as a miss, then call limited_computation exactly once outside the cache-error catch. If it returns a cacheable {:ok, value}, attempt a best-effort put in a separate catch and return the original result even when that put fails. Never retry or swallow an exit from limited_computation itself. Cache only {:ok, value} results whose external_size(value) is at most 1_048_576.

- [ ] **Step 4: Integrate exact immutable keys**

Use these key families:

~~~elixir
{storage_path, :commit_summary, snapshot_oid}
{storage_path, :tree_history, snapshot_oid, tree_path, page, per_page}
{storage_path, :repository_analysis, snapshot_oid, normalized_limits}
{storage_path, :diff_commit, commit_oid, normalized_limits}
~~~

Do not cache ref summary/page, commit page, blobs/README, search, disk usage, list_refs, pack, or receive operations. Put Cache.fetch outside ScanLimiter so hits acquire no permit.

- [ ] **Step 5: Prove push and GC behavior**

Resolve one OID, cache its immutable result, push a new OID, and assert the next request uses a new key. Repack the same repository and assert disk usage changes are visible because size is uncached.

- [ ] **Step 6: Run and commit**

~~~sh
mix test apps/git_core/test/repository_read_model_test.exs --only cache --trace
mix test apps/git_core/test/git_core_test.exs
mix test apps/git_transport/test/git_transport_test.exs
git add apps/git_core/lib/git_core/cache.ex apps/git_core/lib/git_core/application.ex apps/git_core/lib/git_core.ex apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): cache immutable repository reads"
~~~

## Task 13: Build repository orchestration and README rewriting

**Files:**

- Add: apps/fornacast_web/lib/fornacast_web/repository_page.ex
- Add: apps/fornacast_web/lib/fornacast_web/repository_markdown.ex
- Add tests: apps/fornacast_web/test/repository_page_test.exs
- Add tests: apps/fornacast_web/test/repository_html_test.exs
- Modify: apps/forge_repos/lib/forge_repos.ex

- [ ] **Step 1: Add a narrow fake GitCore seam**

In repository_page_test.exs, implement a test module with the same read functions and a call log. Pass it as git_core: FakeGitCore. The production default remains GitCore.

- [ ] **Step 2: Add failing orchestration tests**

Cover:

- ref_summary/2 or ref_summary_for_route/2 is always the first GitCore call;
- empty repository makes no commit-derived call;
- missing configured default yields {:missing_default_ref, ref_summary};
- one resolve_snapshot call;
- the same snapshot OID reaches summary, tree, README/blob, language, and search;
- commit detail resolves and diffs the URL SHA while ref is chrome context only;
- no task or call per tree row;
- required errors remain typed;
- README, language, and disk optional failures degrade only their panels;
- all returned blob leases appear in the result lease list.

- [ ] **Step 3: Define typed page results**

Use:

~~~elixir
defmodule FornacastWeb.RepositoryPage.Result do
  @enforce_keys [:kind, :chrome, :content]
  defstruct [:kind, :chrome, :content, leases: []]
end

defmodule FornacastWeb.RepositoryPage.Chrome do
  @enforce_keys [:owner, :repository, :viewer, :ref_summary, :clone]
  defstruct [:owner, :repository, :viewer, :ref_summary, :snapshot, :clone]
end

defmodule FornacastWeb.RepositoryPage.Clone do
  @enforce_keys [:https_url]
  defstruct [:https_url, :ssh_url, push_commands: []]
end

defmodule FornacastWeb.RepositoryPage.Code do
  @enforce_keys [:commit_summary, :tree]
  defstruct [:commit_summary, :tree, :readme, :analysis, :disk_usage]
end

defmodule FornacastWeb.RepositoryPage.Tree do
  @enforce_keys [:path, :tree]
  defstruct [:path, :tree]
end

defmodule FornacastWeb.RepositoryPage.Blob do
  @enforce_keys [:path, :blob]
  defstruct [:path, :blob]
end

defmodule FornacastWeb.RepositoryPage.Refs do
  @enforce_keys [:kind, :page]
  defstruct [:kind, :page]
end

defmodule FornacastWeb.RepositoryPage.Commits do
  @enforce_keys [:page]
  defstruct [:page]
end

defmodule FornacastWeb.RepositoryPage.Commit do
  @enforce_keys [:commit, :diff]
  defstruct [:commit, :diff, :ref_context]
end

defmodule FornacastWeb.RepositoryPage.Search do
  @enforce_keys [:query, :scope]
  defstruct [:query, :scope, :results, :validation_error]
end

defmodule FornacastWeb.RepositoryPage.Empty do
  @enforce_keys [:write_access]
  defstruct [:write_access, :disk_usage]
end

defmodule FornacastWeb.RepositoryPage.MissingDefault do
  @enforce_keys [:configured_ref]
  defstruct [:configured_ref]
end

defmodule FornacastWeb.RepositoryPage.Raw do
  @enforce_keys [:blob]
  defstruct [:blob]
end
~~~

Result.kind is one of :code, :tree, :blob, :refs, :commits, :commit, :search, :empty, :missing_default, or :raw. Keep presentation labels and routes in the web module; keep Git values typed. Expose code, tree, blob, refs, commits, commit, search, and raw functions plus release/1. The raw function performs ref summary, exact snapshot resolution, and read_blob_complete/4, then returns a Raw content value whose lease remains held for the controller.

- [ ] **Step 4: Keep concurrency fixed and bounded**

After snapshot resolution, either execute independent scan-only reads serially or run one fixed list of at most four named scan tasks. Never derive tasks from tree rows or search results. Blob-producing reads, including README, inline blob, and complete raw, always run in the request process that will render or send the response; do not acquire a BlobLimiter lease in a short-lived child task. Ensure every successful scan task is joined and every acquired blob lease is released on failure.

- [ ] **Step 5: Add HTTPS and actor-correct clone URLs**

Add ForgeRepos.http_clone_url/2 using Fornacast.Config.base_url/0 plus /owner/repo.git. Anonymous and disabled viewers of a public repository receive HTTPS only. An active signed-in permitted actor also receives SSH. Empty push commands appear only when Fornacast.Access.authorize(viewer, :repository_write, repository) returns :ok.

- [ ] **Step 6: Add failing Markdown rewrite tests**

Cover README.md, README, README.txt priority; nested relative links; relative raster images; non-raster images converted to linked alt text; same-document anchors; http, https, and mailto preservation; selected full-ref preservation; percent encoding; parent traversal rejection; unsupported schemes; and raw HTML sanitization. Tag these cases :markdown.

- [ ] **Step 7: Rewrite MDEx AST before sanitization**

Use:

~~~elixir
markdown
|> MDEx.parse_document!()
|> MDEx.Document.update_nodes(MDEx.Link, &rewrite_link(&1, context))
|> MDEx.Document.update_nodes(MDEx.Image, &rewrite_image(&1, context))
|> MDEx.to_html!(sanitize: MDEx.Document.default_sanitize_options())
~~~

Normalize relative paths against the README directory without allowing a path above repository root. Use source/blob routes for document links and authorized raw routes for images. Return Phoenix-safe sanitized output.

- [ ] **Step 8: Run and commit**

~~~sh
mix test apps/fornacast_web/test/repository_page_test.exs --trace
mix test apps/fornacast_web/test/repository_html_test.exs --only markdown --trace
git add apps/fornacast_web/lib/fornacast_web/repository_page.ex apps/fornacast_web/lib/fornacast_web/repository_markdown.ex apps/fornacast_web/test/repository_page_test.exs apps/fornacast_web/test/repository_html_test.exs apps/forge_repos/lib/forge_repos.ex
git commit -m "feat(web): compose immutable repository pages"
~~~

## Task 14: Render the DuskMoon repository surface

**Files:**

- Modify: .formatter.exs
- Modify: mix.exs
- Modify only if dependency resolution changes it: mix.lock
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html.ex
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html/code.html.heex
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html/tree.html.heex
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html/blob.html.heex
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html/refs.html.heex
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html/commits.html.heex
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html/commit.html.heex
- Add: apps/fornacast_web/lib/fornacast_web/controllers/repository_html/search.html.heex
- Modify: apps/fornacast_web/lib/fornacast_web/html.ex
- Modify: apps/fornacast_web/assets/css/app.css
- Modify: apps/fornacast_web/assets/js/app.js
- Add tests: apps/fornacast_web/test/repository_html_test.exs

- [ ] **Step 1: Add failing component-contract tests**

Render components directly. Assert repository identity, visibility, selected ref, exact counts, active aria-current navigation, canonical full-ref URLs with short labels, absence of future tabs/actions, escaping, form labels, status region, and anonymous brand/Login/Theme shell without authenticated controls.

- [ ] **Step 2: Enable the real HEEx formatter**

Add Phoenix.LiveView.HTMLFormatter beside DuskmoonBundler.Formatter in .formatter.exs and include heex in the existing recursive input extension list. Add phoenix_live_view ~> 1.2 as a root-only development, runtime-false dependency in mix.exs so the umbrella formatter can load its plugin. Run mix deps.get here; Step 9 checks every new HEEx template with the loaded formatter.

- [ ] **Step 3: Add the repository shell**

Add HTML.repository_page/3 accepting Phoenix-safe iodata. Build its outer document as an iolist and convert to a binary only at the final send_resp boundary. Authenticated pages keep the current appbar but omit the generic Repository workbench heading and generic outer panel. Anonymous pages use a normal repository-width shell, not auth-shell, with only brand, Login, and Theme actions. Convert the rendered RepositoryHTML fragment with Phoenix.HTML.Safe.to_iodata/1 and pass that safe iodata to HTML.repository_page/3; never interpolate Phoenix.LiveView.Rendered or a plain list back into the current binary-string shell.

- [ ] **Step 4: Create shared HEEx components**

Use RepositoryHTML with embed_templates. Build one shared repository_frame, header, navigation, ref controls, server-link breadcrumbs, server-link pagination, clone popover, optional-state panel, and copy status region.

Use these primary DuskMoon mappings:

- dm_git_repository_header for owner/name/visibility/description/meta/actions; pass the selected short branch/tag label to its default_ref attribute and show the configured default branch separately in meta. In the missing-default state, show the configured value plus the mismatch message and available refs;
- dm_git_repository_nav for Code, Commits, Branches, Tags only;
- dm_git_file_tree for commit-aware rows, with row.name as filename, row.path as latest commit title, row.meta as compact relative time, and row.href as the directory/blob destination;
- dm_git_blob_viewer for bounded blob states and Raw;
- dm_git_commit_diff for structured files and lines;
- dm_git_clone_box with explicit URL and command slots;
- dm_table, dm_input, dm_select, dm_popover, and dm_link for remaining controls.

- [ ] **Step 5: Mark server-navigation dependency workarounds**

Do not invoke the broken dm_breadcrumb or dm_pagination wrappers. Compose DuskMoon links at those two callsites and place:

~~~heex
<%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#82 --%>
<%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#83 --%>
~~~

Use explicit empty-repository clone/push command slots because the installed clone-box fallback hardcodes main.

- [ ] **Step 6: Build all page templates**

Code renders exact summary links, selector/Go to file/clone toolbar, latest commit, file tree, README, search, description, size, and language sidebar. Ref controls submit GET /owner/repository with a ref field whose option values are canonical full names, labels are short names, and explicit submit is required; changing a select alone performs no hidden client navigation. When refs_truncated is false, the selector uses the bounded sample. When true, that action renders a labeled Exact full ref input named ref plus Branches and Tags page links instead of an unbounded select. A valid submitted full ref becomes the selected value; legacy bare values remain accepted; a missing or malformed ref follows the approved repository-scoped 404 behavior. Component and controller tests exercise all three outcomes. Empty repositories omit tree, README, and language panels. Partial analysis is labeled Partial language analysis with files/bytes scanned and is not presented as complete percentages. Limiter/native analysis failure says Analysis temporarily unavailable; disk timeout/failure says Size temporarily unavailable; README blob failure says README temporarily unavailable. Tree adds link breadcrumbs and bounded pagination. Blob maps binary, non-UTF-8, truncated, and Raw states. Refs, commits, and search use compact DuskMoon tables. Commit maps DiffLine values directly without parsing patch text.

- [ ] **Step 7: Load dependency CSS and responsive containment**

Add this import to app.css:

~~~css
@import "phoenix_duskmoon/components";
~~~

Add token-based repository layout rules. Below 1,024 px stack the sidebar; below 768 px scroll tabs horizontally; below 640 px wrap toolbars and make search/clone rows full width. Constrain long paths, snippets, hashes, code, diffs, and README tables to local wrapping/scrollers.

- [ ] **Step 8: Add the clipboard bridge if issue 80 remains open**

Recheck the installed package and upstream issue. If still unfixed, add one delegated listener:

~~~javascript
// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#80
const writeClipboard = async (value, button) => {
  if (window.isSecureContext && navigator.clipboard) {
    return navigator.clipboard.writeText(value)
  }

  const active = document.activeElement
  const textarea = document.createElement("textarea")
  textarea.value = value
  textarea.readOnly = true
  textarea.style.position = "fixed"
  textarea.style.opacity = "0"
  document.body.append(textarea)
  textarea.select()

  try {
    if (!document.execCommand("copy")) throw new Error("copy command rejected")
  } finally {
    textarea.remove()
    if (active instanceof HTMLElement) active.focus()
    else button.focus()
  }
}

document.addEventListener("click", async event => {
  const button = event.target.closest("[data-copy-value]")
  if (!button) return

  const page = button.closest("[data-repository-page]")
  const status = page && page.querySelector("[data-copy-status]")

  try {
    await writeClipboard(button.dataset.copyValue, button)
    if (status) status.textContent = "Copied to clipboard."
  } catch (_error) {
    if (status) status.textContent = "Copy failed. Select and copy the value manually."
  }
})
~~~

The status element uses role=status and aria-live=polite. Native buttons retain keyboard activation and focus. Browser QA must exercise secure Clipboard API success when available, the fallback success path with navigator.clipboard unavailable, and a forced fallback failure.

- [ ] **Step 9: Run and commit**

~~~sh
mix format apps/fornacast_web/lib/fornacast_web/controllers/repository_html/*.heex apps/fornacast_web/assets/js/app.js
mix format --check-formatted apps/fornacast_web/lib/fornacast_web/controllers/repository_html/*.heex
mix test apps/fornacast_web/test/repository_html_test.exs --trace
mix assets.build
git add .formatter.exs mix.exs mix.lock apps/fornacast_web/lib/fornacast_web/controllers/repository_html.ex apps/fornacast_web/lib/fornacast_web/controllers/repository_html apps/fornacast_web/lib/fornacast_web/html.ex apps/fornacast_web/assets/css/app.css apps/fornacast_web/assets/js/app.js apps/fornacast_web/test/repository_html_test.exs
git commit -m "feat(web): render DuskMoon repository pages"
~~~

## Task 15: Cut repository routes and controllers over safely

**Files:**

- Add: apps/fornacast_web/lib/fornacast_web/repository_raw.ex
- Add: apps/fornacast_web/test/repository_controller_test.exs
- Modify: apps/fornacast_web/lib/fornacast_web/router.ex
- Modify: apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex
- Modify: apps/fornacast_web/test/fornacast_web_test.exs

- [ ] **Step 1: Add the public route matrix tests**

Cover anonymous public Code, branches, tags, both commit-history forms, commit, source, raw, and search. Cover permitted private reads. For the same viewer, assert missing and inaccessible private repositories have identical 404 status, body, and normalized content/security/cache/auth headers, and trigger no storage, cache, or Git call. Exclude request-specific x-request-id, date, and server headers from that header comparison.

- [ ] **Step 2: Split router scopes in safe declaration order**

Declare login first, authenticated static/create/import/dashboard routes second, and dynamic repository-read routes last. Keep /repos/new, /repos/import, and POST /repos behind :authenticated. Put repository reads through :browser only and add:

~~~elixir
get "/:owner/:repo/search", RepositoryController, :search
~~~

Leave smart HTTP routes unchanged.

- [ ] **Step 3: Add parameter and state tests**

Cover canonical and legacy refs, slash refs, selected-ref preservation, directories, blobs, README, commits, exact pages, non-positive page 422, out-of-range 404, empty collection page 1, missing default/ref/commit/path, empty reader/writer differences, absent-query search 200, one-to-200-character validation, trimmed queries, retained ref/query/scope on invalid search 422, unsupported scope, no results, and sanitized required 503. For search truncation, assert File scan limit reached, Content byte limit reached, Search time limit reached, and Result limit reached for their corresponding atoms, with multiple reasons rendered once in fixed file/byte/deadline/result order. Do not add blob line anchors or search highlighting in this slice.

- [ ] **Step 4: Replace wildcard tree probing with the first ref-summary scan**

Normalize unambiguous canonical query refs into RefSelector values. Pass source/raw route segments and legacy or slash-containing route refs to RepositoryPage without touching storage in the controller. RepositoryPage calls GitCore.ref_summary_for_route/2 as its first Git operation; that one bounded scan returns the summary, longest exact typed selector, and remaining Git path. It then resolves the selector exactly once. Remove the current progressively shorter read_tree/3 probes.

- [ ] **Step 5: Centralize controller mapping**

The controller owns parsing, positive-page validation, authorization, status/headers, redirects, raw sending, and RepositoryHTML template selection. RepositoryPage owns orchestration. Map only GitCore.Error.kind. Log only the stable kind and operation plus repository ID and request ID; do not log detail at this HTTP boundary. Never render detail, absolute paths, inspected terms, or native strings. Use ExUnit.CaptureLog to assert repository ID/request context remain while the storage root, native reason text, stack traces, and inspected internal terms are absent.

- [ ] **Step 6: Implement uniform repository 404**

Use one title, body, and repository-shell state for not found and unauthorized. Authorization must complete before ForgeRepos.absolute_storage_path/1. Missing ref/commit/path uses a repository-scoped 404 with a link to the current default Code page.

- [ ] **Step 7: Add safe raw headers**

In RepositoryRaw, remove control characters, escape quoted-string backslash and quote, create an ASCII fallback, and append RFC 5987 UTF-8 filename*. Allow only png, jpg/jpeg, gif, webp, and avif raster MIME types case-insensitively. Use application/octet-stream for HTML, SVG, and all other extensions. Always send X-Content-Type-Options: nosniff.

Add controller assertions for CR/LF and other controls, quote, backslash, non-ASCII UTF-8 filename*, ASCII fallback, every allowlisted raster extension including mixed case, HTML/SVG fallback, and nosniff.

- [ ] **Step 8: Hold raw and rendered leases through response completion**

Wrap RepositoryPage rendering and GitCore.read_blob_complete/4 responses in try/after. Release after HTML.repository_page/3 or send_resp/3 returns, and on every error branch. Map oversized raw to 413 and blob-busy raw to 429 with Retry-After: 1. Never send a truncated complete read as 200.

Assert byte-for-byte complete 200 bodies, oversized 413 without a prefix body, raw-busy Retry-After, and exactly one release for every acquired lease after successful send, send failure, render failure, or discarded body. Assert zero acquisitions and releases for :blob_too_large and every failure that occurs before acquisition.

- [ ] **Step 9: Add failure and race tests**

Cover:

- search busy 429 with Retry-After: 1;
- raw busy 429;
- required inline blob busy 503;
- README busy panel degradation;
- language/disk busy or timeout panel degradation;
- cache failure recomputation;
- corrupt/unavailable storage 503;
- a push after snapshot resolution cannot mix OIDs within the response;
- a later request resolves the new OID and cache key;
- commit detail diffs URL SHA despite another ref context.

- [ ] **Step 10: Retire repository string renderers**

Remove repo_header, repo_tabs, refs_table, commits_table, commit_detail, tree_view, blob_view, readme_preview, and mutable resolve_ref_and_path probing after every read route uses RepositoryPage/RepositoryHTML. Keep repository create/import form helpers on the existing HTML path.

- [ ] **Step 11: Run and commit**

~~~sh
mix test apps/fornacast_web/test/repository_controller_test.exs --trace
mix test apps/fornacast_web/test/repository_page_test.exs
mix test apps/fornacast_web/test/repository_html_test.exs
mix test apps/fornacast_web/test/fornacast_web_test.exs
git add apps/fornacast_web/lib/fornacast_web/repository_raw.ex apps/fornacast_web/lib/fornacast_web/router.ex apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex apps/fornacast_web/test/repository_controller_test.exs apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(web): expose public repository reads"
~~~

## Task 16: Verify the complete slice and remote browser behavior

**Files:**

- Modify: config/dev.exs
- Modify only if its existing assertion needs the explicit IPv4 contract: apps/fornacast_web/test/fornacast_run_task_test.exs
- Add: scripts/repository_qa_fixture.exs
- Modify: this plan only to check completed boxes

- [ ] **Step 1: Make the development listener explicitly IPv4-remote**

Change only the development endpoint IP from the IPv6 unspecified tuple to:

~~~elixir
http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4890"))]
~~~

Do not change the production endpoint bind contract.

- [ ] **Step 2: Add an idempotent browser-QA fixture**

Create scripts/repository_qa_fixture.exs and run it with mix run. Using existing account/repository contexts plus fixture-local collaborator insertion, idempotently create:

- qa-owner with the documented fixture password, owning a populated public repository, an empty public repository, and a populated private repository;
- qa-reader with read collaboration on the private repository;
- qa-denied with no private access.

The populated Git fixture uses fixed author/committer timestamps and contains two commits, README relative document/raster/SVG links, text and binary blobs, a nested directory, more than 200 direct children for tree pagination, more than 100 deterministic search matches, a feature/slash branch, an annotated tag, and a real multi-file commit diff. The script may reset only repositories carrying its exact qa fixture slugs, must be safe to run twice, and prints the routes and non-secret test credentials it created. A --cleanup argument removes only these exact QA records and storage paths, making teardown reproducible without touching user data.

Run twice to prove idempotence:

~~~sh
mix run scripts/repository_qa_fixture.exs
mix run scripts/repository_qa_fixture.exs
~~~

- [ ] **Step 3: Format and inspect the scoped diff**

~~~sh
mix format \
  .formatter.exs \
  mix.exs \
  apps/git_core/lib/git_core.ex \
  apps/git_core/lib/git_core/application.ex \
  apps/git_core/lib/git_core/native.ex \
  apps/git_core/lib/git_core/read_model.ex \
  apps/git_core/lib/git_core/scan_limiter.ex \
  apps/git_core/lib/git_core/blob_limiter.ex \
  apps/git_core/lib/git_core/cache.ex \
  apps/git_core/test/repository_read_model_test.exs \
  apps/forge_repos/lib/fornacast/access.ex \
  apps/forge_repos/lib/forge_repos.ex \
  apps/forge_repos/test/access_test.exs \
  apps/fornacast_web/lib/fornacast_web/repository_page.ex \
  apps/fornacast_web/lib/fornacast_web/repository_markdown.ex \
  apps/fornacast_web/lib/fornacast_web/repository_raw.ex \
  apps/fornacast_web/lib/fornacast_web/router.ex \
  apps/fornacast_web/lib/fornacast_web/html.ex \
  apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex \
  apps/fornacast_web/lib/fornacast_web/controllers/repository_html.ex \
  apps/fornacast_web/lib/fornacast_web/controllers/repository_html/*.heex \
  apps/fornacast_web/test/repository_controller_test.exs \
  apps/fornacast_web/test/repository_page_test.exs \
  apps/fornacast_web/test/repository_html_test.exs \
  apps/fornacast_web/test/fornacast_web_test.exs \
  apps/fornacast_web/test/fornacast_run_task_test.exs \
  apps/fornacast_web/assets/js/app.js \
  scripts/repository_qa_fixture.exs \
  config/dev.exs
cargo fmt --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml
git diff --check
git status --short
~~~

Confirm every changed line belongs to this specification and no unrelated dirty file is staged.

- [ ] **Step 4: Run the focused acceptance suite**

~~~sh
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml
mix test apps/git_core/test/repository_read_model_test.exs
mix test apps/git_core/test/git_core_test.exs
mix test apps/forge_repos/test/access_test.exs
mix test apps/fornacast_web/test/repository_controller_test.exs
mix test apps/fornacast_web/test/repository_page_test.exs
mix test apps/fornacast_web/test/repository_html_test.exs
mix test apps/fornacast_web/test/fornacast_web_test.exs
mix test apps/fornacast_web/test/fornacast_run_task_test.exs
mix test apps/git_transport/test/git_transport_test.exs
mix assets.build
~~~

Expected: every in-scope test and the asset build pass. If an out-of-scope suite later fails, report it and stop.

- [ ] **Step 5: Start the remote-reachable development server**

Verify port 58211 is unused. Set QA_ORIGIN to the exact origin the in-app browser will use; in the current Codex browser routing that is localhost, while a directly addressed remote browser must use its reachable host. The bind address remains 0.0.0.0 and must never be used as a generated URL.

~~~sh
export QA_ORIGIN=http://localhost:58211
FORNACAST_BASE_URL="$QA_ORIGIN" PORT=58211 mix fornacast.run
~~~

Confirm the startup endpoint is listening on 0.0.0.0:58211 and curl the health and one public repository route before browser work.

- [ ] **Step 6: Use the Chrome DevTools browser skill**

Verify sunshine and moonlight at:

- 1,440 x 900;
- 768 x 1,024;
- 390 x 844.

Use fresh anonymous, qa-reader, qa-owner, and qa-denied sessions against the generated populated and empty repositories.

- [ ] **Step 7: Exercise every working surface**

Verify public/private behavior, missing/private non-disclosure, canonical and slash refs, root/nested trees, branch/tag/history pages, URL-authoritative commit diff, path/content search, no results, truncation, README rewrites, blob states, raw MIME/download behavior, empty reader/writer guidance, clone URLs matching QA_ORIGIN, secure Clipboard API success when available, fallback copy success, and forced copy failure.

- [ ] **Step 8: Inspect actual layout and interaction**

Assert documentElement.scrollWidth is no greater than clientWidth. Verify tabs scroll without wrapping, long paths/diffs remain in local scrollers, clone popover hit-testing works, focus returns sensibly, keyboard focus remains visible, and reduced motion is respected.

Inspect computed border, background, layout, and overflow styles on DuskMoon Git components to prove phoenix_duskmoon/components is present in the generated CSS. Check network and console for failed assets or errors.

- [ ] **Step 9: Recheck upstream workaround state**

~~~sh
gh issue view 80 --repo duskmoon-dev/phoenix-duskmoon-ui
gh issue view 82 --repo duskmoon-dev/phoenix-duskmoon-ui
gh issue view 83 --repo duskmoon-dev/phoenix-duskmoon-ui
~~~

If an installed dependency release fixes a gap, upgrade within the existing 9.x constraint, remove only that workaround, rerun its focused tests and assets, and verify the browser behavior. Otherwise retain the issue-linked callsite.

- [ ] **Step 10: Record the teardown command**

After browser evidence is captured, keep the fixture and server available for user preview. When that preview is no longer needed, stop the server and remove only the generated QA data with:

~~~sh
mix run scripts/repository_qa_fixture.exs -- --cleanup
~~~

- [ ] **Step 11: Commit verification configuration**

~~~sh
git add config/dev.exs apps/fornacast_web/test/fornacast_run_task_test.exs scripts/repository_qa_fixture.exs docs/superpowers/plans/2026-07-16-repository-foundation.md
git commit -m "test(repo): verify repository foundation"
~~~

## Final acceptance checklist

- [ ] Only Code, Commits, Branches, and Tags are visible repository tabs.
- [ ] Every visible control performs a real server or clipboard action.
- [ ] Public reads work anonymously across Code, refs, commits, source, raw, and search.
- [ ] Missing and inaccessible private repositories are indistinguishable.
- [ ] Every ref-backed response uses one immutable snapshot OID.
- [ ] Commit detail resolves and diffs the URL SHA.
- [ ] Commit-aware rows use one bounded native history walk.
- [ ] Counts, pages, search, languages, and disk size match deterministic fixtures.
- [ ] Structured diff values map directly to dm_git_commit_diff.
- [ ] Inline blobs are prefix-bounded and complete raw reads are never truncated successes.
- [ ] Scan, blob, search, analysis, cache, and failure states are tested.
- [ ] DuskMoon Git components are the primary surface and their CSS is loaded.
- [ ] Upstream workarounds are issue-linked and present only while needed.
- [ ] Focused tests, Git transport regression, assets, both themes, and all three viewports pass.
- [ ] The verification server listens on 0.0.0.0 without changing production bind behavior.
