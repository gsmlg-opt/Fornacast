# Repository Foundation Design

Date: 2026-07-16
Status: Pending written-spec review

Planning lineage: within the repository-page scope, this specification replaces
the assumptions in
`docs/superpowers/specs/2026-07-05-forgejo-inspired-duskmoon-ui-design.md` and
the repository tasks in
`docs/superpowers/plans/2026-07-06-forgejo-inspired-duskmoon-ui.md`. The older
plan must not be used for repository implementation; a new implementation plan
will follow approval of this written specification. Its non-repository scope is
unchanged.

## Program Context

Fornacast will grow toward the working repository experience represented by
Forgejo/Gitea, including collaboration, knowledge, automation, and delivery
features. That target is too large for one safe implementation cycle, so it is
split into independently shippable slices:

1. **Repository foundation** — the Code experience and shared repository read
   model described by this specification.
2. **Collaboration** — Watch, Star, Fork, Issues, Pull Requests, reviews, and
   repository activity.
3. **Knowledge and discovery** — Wiki, Projects, and cross-repository search.
4. **Automation and delivery** — Actions, logs, artifacts, Packages, and
   Releases.

The collaboration and knowledge slices may proceed in parallel after this
foundation. Automation and delivery build on repository permissions, refs,
activity, and artifact ownership established by earlier slices.

## Approved Decisions

- The long-term goal is working product parity, not a visual-only reskin.
- This specification covers only the first repository-foundation slice.
- Public repositories are readable without signing in; private repositories
  remain authorization-protected.
- Phase 1 is read-only in the browser. Repository content changes continue to
  arrive through Git push. Browser create/upload/edit/delete is a later slice.
- File-tree rows include the latest commit message and time for each entry.
- Commit, branch, and tag counts are exact rather than decorative estimates.
- Search is scoped to one repository and selected ref in Phase 1.
- Existing controller routes and server navigation remain. Repository rendering
  moves to a targeted HEEx/DuskMoon boundary; this is not a LiveView conversion
  or an application-wide template rewrite.
- Unsupported future tabs and actions remain hidden until their domains work.

## Current State

The current web app renders HTML strings from controllers through
`FornacastWeb.HTML.page/3`. Repository routes already cover overview, branches,
tags, commit history, commit details, source trees, blobs, and raw content.
`GitCore` already exposes refs, history, commit, tree, blob, and diff reads.

The repository root currently renders only metadata, four links, and a README.
It does not render the root tree, latest commit, exact counts, search, language
statistics, repository size, or commit-aware tree rows.

`phoenix_duskmoon` 9.8.0 is installed and provides:

- `dm_git_repository_header`
- `dm_git_repository_nav`
- `dm_git_file_tree`
- `dm_git_blob_viewer`
- `dm_git_commit_diff`
- `dm_git_clone_box`

Those are HEEx function components, so they cannot be invoked directly inside
the current interpolated controller strings.

## Goals

- Make the repository Code page work like a compact forge rather than a README
  shortcut.
- Establish one reusable, authorized repository read model for later features.
- Render repository pages with DuskMoon Git components and DuskMoon tokens.
- Support anonymous public browsing and safe private browsing.
- Provide exact repository summary data, commit-aware directory rows,
  repository/ref-scoped search, language statistics, and repository size.
- Preserve namespace-aware URLs, current Git storage, SSH transport, smart-HTTP
  clone behavior, and existing authorization roles.
- Remain usable in both themes and at desktop and mobile widths.

## Non-Goals

- Watch, Star, Fork, Issues, Pull Requests, reviews, Actions, Packages,
  Projects, Releases, Wiki, or repository activity.
- Cross-repository or global search.
- Browser-based file creation, upload, editing, deletion, or commit creation.
- Regex search, advanced search syntax, blame, or rename-aware path history.
- LiveView conversion.
- Application-wide replacement of controller-generated HTML.
- New Git storage or transport behavior.
- A database-backed search index or durable derived-data cache.
- Pixel-for-pixel Forgejo styling.

## Architecture

### Request Boundary

Repository creation and import remain inside the authenticated router scope.
Read-only repository routes move to the normal browser pipeline, which loads an
optional current user but does not require one:

- `/:owner/:repo`
- `/:owner/:repo/branches`
- `/:owner/:repo/tags`
- `/:owner/:repo/commits/:ref` and the wildcard-ref form
- `/:owner/:repo/commit/:sha`
- `/:owner/:repo/src/*segments`
- `/:owner/:repo/raw/*segments`
- new `/:owner/:repo/search`

Every read route resolves the namespace and repository, calls
`Fornacast.Access.authorize/3`, and only then touches repository storage.

`FornacastWeb.RepositoryController` remains responsible for HTTP concerns:

- parsing owner, repository, ref, path, search scope, and query values;
- mapping authorization and Git results to status codes;
- redirects and raw responses;
- selecting the repository page state to render.

### Repository Page Read Boundary

A new `FornacastWeb.RepositoryPage` module owns page-specific orchestration. It
accepts an already authorized repository, owner, viewer, typed ref selector,
and path, then returns typed view models. It never emits HTML.

For a non-empty ref-backed request it:

1. Loads the bounded current-ref summary and handles an empty repository before
   any commit-derived call.
2. Resolves the requested full ref once to a
   `%GitCore.Snapshot{ref: full_ref, oid: oid}`.
3. Passes `snapshot.oid`, never the mutable ref name, to commit summary,
   commit history, commit-aware tree, README/blob, language, and search reads.
4. Loads repository disk size separately because it describes the whole bare
   repository rather than one commit snapshot.
5. Builds one internally consistent model for `RepositoryHTML`.

Commit detail is intentionally different: `/:owner/:repo/commit/:sha` resolves
the requested SHA once to its canonical commit OID and diffs that commit. An
optional selected ref supplies repository chrome and back-links only; its tip
must never replace the commit named by the URL.

Independent reads may run concurrently after ref resolution, but the design
must not create one task or one native call per tree row.

### Presentation Boundary

A new `FornacastWeb.RepositoryHTML` module uses `FornacastWeb, :html`, targeted
HEEx templates, and the installed DuskMoon components. The controller converts
the rendered HEEx fragment to safe iodata and passes it through a repository
variant of the existing shared shell.

The repository shell variant keeps the current Fornacast appbar and theme
behavior while omitting the generic “Repository workbench” page heading and
generic content panel that would duplicate the repository header.
When no user is signed in, it renders a public repository shell with Login and
Theme actions rather than the focused login/setup form shell. The anonymous
appbar contains only the Fornacast brand on the left and Login + Theme on the
right; authenticated-only global navigation, create, repository, and account
menus are absent.

Other application pages remain on their current rendering path.

This design adds no database schema or repository-storage migration.

### Asset Contract

The installed PhoenixDuskmoon package requires its exported component CSS. Add
`@import "phoenix_duskmoon/components";` to the existing
`apps/fornacast_web/assets/css/app.css` Tailwind entry, following the package's
documented setup. Do not copy dependency utility rules into local CSS. The
existing DuskmoonBundler dependency resolver remains the asset entrypoint;
`mix assets.build` and browser computed-style checks must prove the Git
component classes are present in the generated bundle.

### GitCore Boundary

Expensive repository reads stay in `GitCore` and its Rust NIF rather than being
reimplemented in controllers. New repository scans must use the same
`DirtyIo` scheduling convention as existing native Git operations.

The Elixir API exposes explicit structs for summary, tree history, search
results, and analysis. Web code maps those structs into presentation models; it
does not parse native tuples ad hoc.

All repository read APIs return `{:ok, value}` or
`{:error, %GitCore.Error{kind: kind, operation: operation, detail: detail}}`.
Stable `kind` values are:

- `:empty_repository`;
- `:ref_not_found`;
- `:commit_not_found`;
- `:path_not_found`;
- `:blob_too_large`;
- `:blob_busy`;
- `:invalid_repository`;
- `:storage_unavailable`;
- `:corrupt_repository`;
- `:scan_timeout`;
- `:scan_busy`.

`detail` is diagnostic-only and may be logged after redaction. Controllers map
only `kind`; they never parse native reason strings.

HTTP/page mapping is deterministic:

| GitCore error kind | Repository behavior |
| --- | --- |
| `:empty_repository` | `200` empty-repository state |
| `:ref_not_found`, `:commit_not_found`, `:path_not_found` | repository-scoped `404` |
| `:blob_too_large` | `413` for an over-limit raw response; inline reads use the normal truncated blob state |
| `:blob_busy` | raw/required/optional mapping described below |
| `:invalid_repository`, `:storage_unavailable`, `:corrupt_repository` | sanitized `503` |
| `:scan_timeout`, `:scan_busy` | required/optional mapping described below |

A supervised `GitCore.ScanLimiter` permits at most four concurrent native
ref-summary/page, commit-summary/page, tree-history, structured-diff, search,
language-analysis, or disk-usage operations application-wide. A caller waits
up to 250 ms for a permit. Busy search requests return `429` with
`Retry-After: 1`; busy ref, summary, history, tree, or diff operations return the
sanitized `503` state; busy language or disk analysis degrades only that
optional panel and can retry on the next request.

Exact ref-summary/page, commit-summary/page, tree-history, and structured-diff
walks check a five-second native deadline; timeout returns `:scan_timeout` and
never returns inexact required data. Search and language analysis use their
shorter bounded-result contracts, while disk usage uses its shorter optional
contract described below. Native loops check their deadline and work bounds so
an HTTP timeout does not leave unbounded work running on a dirty scheduler.

A separate supervised `GitCore.BlobLimiter` protects materialized blob data. It
allows at most eight reads and 128 MiB of declared uncompressed blob bytes in
flight application-wide. A caller waits up to 250 ms. Inline reads reserve their
1 MiB limit; complete raw reads inspect object metadata without loading content,
then reserve the exact size before allocation. The permit remains held until the
web response has sent or discarded the body. Busy raw responses return `429`
with `Retry-After: 1`; a required blob page uses the sanitized `503` state, while
an optional README panel renders “README temporarily unavailable.”

## Repository Read Contracts

### Ref Selection

- The root Code page defaults to `repository.default_branch`.
- Generated root/search URLs use the canonical full ref in
  `?ref=refs/heads/<name>` or `?ref=refs/tags/<name>`; option labels remain the
  short display name.
- Directory, blob, commit, search, and “Go to file” links preserve the selected
  canonical full ref.
- Source, raw, and commit-history wildcard paths carry the same full ref. The
  controller matches the longest full ref of the declared kind before treating
  remaining segments as a repository path, so names containing `/` stay
  lossless.
- Legacy bare ref values remain accepted for existing links. They resolve a
  branch first and then a tag; every newly rendered link uses the canonical full
  ref so a branch and tag with the same display name are never ambiguous.
- A missing configured default branch is not silently replaced. The page shows
  the available refs and explains the mismatch.

### Ref and Snapshot Summary

`GitCore.ref_summary(path, selected_ref: full_ref)` always runs first and returns
`%GitCore.RefSummary{branch_count: branch_count, tag_count: tag_count,
branches: branches, tags: tags, refs_truncated: refs_truncated}`. Each retained
ref includes its full name, display name, kind, and target OID. Counts are exact,
but the selector retains at most the first 100 bytewise-sorted refs of each kind
plus the selected ref when it falls outside that sample. Empty repositories
return zero counts and empty lists, not a missing OID placeholder.

When `refs_truncated` is true, the selector exposes an exact-name ref input and
links to the paginated Branches and Tags pages rather than constructing an
unbounded dropdown. `GitCore.ref_page(path, kind, page, per_page: 100)` provides
those pages with exact totals and deterministic bytewise name ordering. Invalid
non-positive page values return `422`; positive pages beyond the final page
return the repository-scoped `404` state.

For every paginated collection, an empty collection accepts page 1 and renders
its empty state; page 2 or later returns the repository-scoped `404` state.

For a non-empty repository,
`GitCore.resolve_snapshot(path, %GitCore.RefSelector{kind: kind,
full_name: full_ref})` returns one
`%GitCore.Snapshot{kind: kind, ref: full_ref, oid: commit_oid}` or a typed
`:ref_not_found` error. Branches resolve directly to their commit; annotated tags
peel recursively to a commit. A tag that does not ultimately target a commit is
not browseable and returns `:ref_not_found`. The configured default branch is
normalized to `refs/heads/<name>`. A missing configured default branch is
represented by the page state `{:missing_default_ref, ref_summary}`;
commit-derived functions are not called.

`GitCore.commit_summary(path, snapshot_oid)` returns:

- exact count of unique commits reachable through all parents from the selected
  commit;
- latest commit metadata for the selected commit.

Branch and tag counts come from `ref_summary.branch_count` and
`ref_summary.tag_count`; they describe the whole repository's current refs even
when the selector sample is truncated.

Commit traversal is topological from the selected OID and visits all parents.
Where topological candidates tie, committer time descending and then OID provide
deterministic order. The exact count includes every unique reachable merge and
root commit, not only the first-parent chain.

`GitCore.commit_page(path, snapshot_oid, page, per_page: 50)` drives commit
history. `page` is a positive integer validated by the web boundary. Results use
the same deterministic traversal, contain at most 50 commits, and return the
exact total/page count for Previous/Next navigation. Commit-history reads always
consume the resolved snapshot OID. A busy or timed-out exact history walk
returns the required `503` state rather than a partial page. Invalid non-positive
page values return `422`; positive pages beyond the final page return the
repository-scoped `404` state.

### Commit-Aware Trees

`GitCore.read_tree_with_history(path, snapshot_oid, tree_path, page,
per_page: 200)` returns one bounded page of direct children with each child's
existing name, kind, mode, and OID plus the latest commit that touched that
current path:

- commit OID;
- title;
- author name;
- author timestamp.

For directories, “touched” means a commit changed a path beneath that directory.
The history walk uses the same deterministic topological order as commit
summary. A commit touches a path when its tree entry differs from its first
parent; a root commit compares against an empty tree. Merge commits therefore
use their first parent for row attribution even though exact commit counting
still traverses all parents. One native history walk fills all rows on the
selected directory page. Phase 1 follows the current path and does not attempt
rename tracking.

Direct children sort deterministically with directories first and then by
UTF-8 name bytes. `page` is a positive integer validated by the web boundary.
The result includes exact `total_entries` and `total_pages`, renders at most 200
rows, and exposes Previous/Next navigation that preserves ref and tree path.
One native history walk fills only the selected page's direct children; no
unbounded directory result or cache value is constructed. Invalid non-positive
page values return `422`; positive pages beyond the final page return the
repository-scoped `404` state.

### Structured Commit Diffs

Extend `GitCore.diff_commit/3` so its bounded result can directly feed
`dm_git_commit_diff`. Each changed file includes:

- path, status, old/new OID, and binary state;
- additions, deletions, and per-file truncation;
- ordered `%GitCore.DiffLine{type, old_line, new_line, content}` entries, where
  `type` is `:context`, `:added`, `:deleted`, or `:hunk`.

The existing combined patch remains for compatibility. The 200,000-byte limit
applies once to retained source diff material; the combined patch and structured
lines are two representations derived from those same retained bytes, not two
independently budgeted payloads. At most 1,000 changed-file sections are
retained. One global `truncated` flag and per-file flags identify omitted files
or display lines. Changed-file, additions, and deletions totals describe the
complete diff even when display data is truncated; if the five-second walk
cannot compute exact stats, the whole operation returns `:scan_timeout` instead
of partial stats. Binary files carry metadata but no text lines. The web layer
does not attempt to parse the unified patch back into component data.

### Blob and Raw Reads

Inline blob views call
`GitCore.read_blob(path, snapshot_oid, blob_path, limit: 1_048_576)` and may
return the normal bounded `%GitCore.Blob{truncated: true}` state with `200`.
The native reader inspects object size first and incrementally decompresses at
most the requested prefix; it must not materialize the complete object and then
truncate in Elixir.

Raw responses call
`GitCore.read_blob_complete(path, snapshot_oid, blob_path, limit: 100_000_000)`.
The native boundary checks object size before allocating the body and returns
`:blob_too_large` when the complete object exceeds that limit. A raw route
therefore returns either the complete body with `200` or `413`; it never sends a
truncated prefix as a successful raw file. Both inline and complete reads acquire
the `GitCore.BlobLimiter` permit before materializing bytes.

Raw response filenames use a centralized Content-Disposition encoder: remove
control characters, escape quoted-string backslash/quote characters, provide a
safe ASCII fallback, and add an RFC 5987 UTF-8 `filename*` value. Raw content
remains `application/octet-stream` except for a case-insensitive allowlist of
`.png` (`image/png`), `.jpg`/`.jpeg` (`image/jpeg`), `.gif` (`image/gif`),
`.webp` (`image/webp`), and `.avif` (`image/avif`) used by README images. Active
formats such as HTML and SVG remain octet-stream. Responses retain
`X-Content-Type-Options: nosniff`.

### Repository Search

The search route accepts:

- `ref` — canonical full branch or tag ref, defaulting to the repository default
  branch;
- `q` — trimmed query, one to 200 characters;
- `scope` — `path` or `content`.

`GitCore.search_tree(path, snapshot_oid, query, opts)` searches only the selected
commit snapshot:

- Path scope performs case-insensitive literal matching against tree paths.
- Content scope performs case-insensitive literal matching against valid UTF-8,
  non-binary blobs.
- Content search skips blobs larger than 1 MiB.
- One request scans at most 10,000 files and 64 MiB of eligible blob content.
- The native scan checks a two-second monotonic deadline.
- Results are capped at 100 and carry an ordered `truncated_reasons` list whose
  allowed atoms are `:file_limit`, `:byte_limit`, `:deadline`, and
  `:result_limit`. The list contains each bound that stopped the scan in that
  fixed display order; `truncated` is derived from the list being non-empty.
- Content results include path, one-based line number, and a bounded line
  snippet of at most 240 characters.
- Regex and cross-repository search are deferred.

Search results preserve the ref, display the matching line number, and link to
the matching blob page. Phase 1 does not add blob line anchors or match
highlighting because `dm_git_blob_viewer` has no line-context API. Query, path,
and snippet data are escaped at render time.

Native traversal is deterministic before the cap: path results sort by bytewise
path; content results sort by bytewise path and then one-based line number, with
at most one result per matching line. The first 100 results in that order are
retained, so repeated requests against the same snapshot return the same page.

A request without `q` renders the search form with `200`. A blank/overlong
query or unsupported scope renders the same page with retained values, an
inline validation error, and `422`. A missing ref remains a repository-scoped
`404`.

### Language and Size Analysis

`GitCore.repository_analysis(path, snapshot_oid)` walks the selected tree and returns
byte-weighted language totals for recognized, non-binary blobs. Classification
uses a deterministic extension table with a shebang fallback. Unknown text
files are grouped as `Other`; submodules and binary blobs are excluded.

One language scan processes at most 100,000 files, 512 MiB of eligible blob
content, or two seconds of native work. Reaching one of those cooperative bounds
returns the bounded result with files/bytes scanned and `truncated`. A truncated
result is labeled “Partial language analysis” and never presented as complete
percentages. A limiter-busy or unexpected native-timeout failure instead renders
“Analysis temporarily unavailable.”

`GitCore.repository_disk_usage(path)` returns the total on-disk size of the bare
repository and checks a two-second deadline. Language percentages therefore
describe the selected source tree, while the displayed repository size
describes all stored Git data. If disk usage times out, the page renders “Size
temporarily unavailable” rather than a stale value.

Vendor/generated-file heuristics beyond this deterministic classifier are a
later analysis enhancement.

## Cache Design

`GitCore.Cache` is a supervised, disposable ETS cache. Source-of-truth data
always remains the bare repository.

- Commit-derived keys use the trusted canonical storage path + immutable commit
  OID + operation and every semantic argument, including tree path, page, and
  diff options where applicable. GitCore therefore owns only keys it can derive
  from its own inputs.
- Cached values include commit summary, tree history, language analysis, and
  structured commit diffs.
- Search queries are not cached because query cardinality is unbounded.
- Ref lists/counts, README discovery/content, and disk usage are not cached.
- The cache holds at most 512 entries and 64 MiB measured with
  `:erlang.external_size/1`, with a 15-minute idle expiry. A value larger than
  1 MiB is not cached. Least recently accessed entries are removed when either
  bound is reached.
- Any cache process or lookup failure falls back to direct computation through
  the same scan limiter and deadlines.

The earlier visual discussion included a mutable repository generation. The
written contract deliberately removes mutable values from the cache: ref
fingerprints cannot detect repack/GC disk-size changes, and `last_pushed_at` is
truncated to seconds. A push resolves to a new snapshot OID and therefore a new
immutable cache key; old commit keys expire naturally. Git transport never
calls or depends on this cache.

## Code Page Composition

### Header and Navigation

The page begins with `dm_git_repository_header`:

- `owner/repository` identity;
- visibility;
- selected/default ref;
- description;
- last-pushed metadata.

`dm_git_repository_nav` exposes only working Phase 1 destinations:

- Code;
- Commits;
- Branches;
- Tags.

Later slices append their tabs when their routes and domains exist. Phase 1
does not render disabled Issues, Pull Requests, Actions, Packages, Projects,
Releases, Wiki, Activity, Watch, Star, or Fork controls.

### Root Code Layout

Desktop uses a fluid main column and a narrower metadata sidebar.

The main column contains, in order:

1. exact commit/branch/tag summary links;
2. ref selector, “Go to file,” and Code/clone controls;
3. latest-commit strip;
4. `dm_git_file_tree` with commit title and time on each row;
5. sanitized README panel when a supported README exists.

The file-tree mapping stays within the installed component API:

- `row.name` is the filename;
- `row.path` is the latest commit title;
- `row.meta` is a compact relative time;
- the row link opens the directory or blob;
- the separate latest-commit strip links to commit detail.

Phase 1 does not make each row’s commit title a second independent link.

The sidebar contains:

- repository/ref-scoped code search;
- description and README jump link;
- repository disk size;
- byte-weighted language bar and legend.

“Go to file” links to the same search route in `path` scope. The Code control
opens a DuskMoon clone surface rather than navigating away.

### Other Repository Views

All repository views reuse the same header and route navigation.

- Directory pages add DuskMoon breadcrumbs/up navigation and another
  commit-aware file tree.
- Blob pages use `dm_git_blob_viewer` with filename, size, raw action, bounded
  content, and binary/non-UTF-8 states.
- Commit detail resolves the URL SHA independently and uses
  `dm_git_commit_diff` with the structured bounded diff data.
- Branch, tag, commit-history, and search pages use compact DuskMoon tables or
  lists with ref-preserving links.
- README rendering continues through sanitized MDEx output inside a DuskMoon
  surface.

### README Links and Images

`FornacastWeb.RepositoryMarkdown` renders the first existing candidate from the
current `README.md`, `README`, and `README.txt` list. For Markdown it resolves
relative destinations against the README’s directory before sanitization:

- relative document links target the selected ref’s source/blob route;
- allowlisted relative raster images target the selected ref's authorized raw
  route;
- other relative image formats render as linked alt text to the authorized raw
  route rather than as an inline image;
- same-document anchors remain anchors;
- absolute `https`, `http`, and `mailto` destinations remain unchanged;
- normalized paths that would escape above the repository root are rejected;
- unsupported schemes are removed by sanitization.

Every rewritten repository URL preserves the selected ref. This prevents
relative README links and images from accidentally resolving against the
browser route or the default branch.

### Responsive Behavior

- At widths below 1,024 px, sidebar sections stack below the main content.
- At widths below 768 px, repository tabs scroll horizontally rather than
  wrapping into ambiguous rows.
- At widths below 640 px, toolbars wrap and full-width search/clone controls
  move to their own row.
- On phones, `dm_git_file_tree` keeps the relative time in its supported compact
  right-side `meta`; the commit title remains the secondary `path` beneath the
  filename and wraps within the component before forcing page overflow.
- Long names, paths, snippets, hashes, code, diffs, and README tables wrap or
  scroll inside controlled containers.

Browser acceptance viewports are 1,440 × 900, 768 × 1,024, and 390 × 844.

## Clone and Copy Behavior

- Anonymous viewers of a public repository see the smart-HTTP clone URL.
- Signed-in permitted viewers see smart HTTP plus an actor-correct SSH URL.
- Writers/admins viewing an empty repository also see push commands.
- Readers never see mutation instructions they cannot execute.
- Copy controls provide keyboard activation and accessible success/failure
  feedback.

The installed DuskMoon Git components currently render `data-copy-value`
buttons without clipboard behavior. This is tracked as
[duskmoon-dev/phoenix-duskmoon-ui#80](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/80),
typed `Bug` with the `internal request` label and severity `needed`.

Implementation must recheck issue `#80` and the installed package first. If the
package is still unfixed, Fornacast adds one delegated clipboard bridge marked:

```javascript
// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#80
```

The bridge must be removed after the dependency provides the behavior.

## Authorization Contract

| Viewer | Repository | Result | Clone controls |
| --- | --- | --- | --- |
| Anonymous | Public | Full read experience, including search/raw | HTTPS |
| Signed-in reader | Public or permitted private | Full read experience | HTTPS + actor-correct SSH |
| Writer/admin | Permitted | Full read experience; push guidance for empty repos | HTTPS + SSH |
| Any unpermitted viewer | Private or missing | Identical `404` | None |

An inaccessible private repository and a missing repository deliberately share
the same response to avoid existence leaks. This replaces the current visible
`403` behavior for unauthorized private repository pages.

## Empty and Failure States

### Expected States

- **Empty repository:** preserve header and zero counts. Anonymous/read-only
  viewers get clone and empty guidance; writers also get push commands. Do not
  render a fake tree, README, or language panel.
- **Binary/non-UTF-8 blob:** return `200` with an explicit non-renderable state
  and authorized Raw action.
- **Large blob:** return `200` with the existing bounded/truncated viewer and an
  authorized Raw action.
- **Oversized raw blob:** return `413`; never send a truncated file with `200`.
- **Search cap reached:** show the first 100 results and a visible truncation
  notice naming the file, byte, time, or result bound reached.
- **No search results:** return `200`, preserve query/ref, and offer scope
  changes.
- **Invalid search:** return `422` with the selected ref, query, scope, and
  inline validation error preserved.
- **Partial language analysis:** return `200` and label the language panel as
  partial with the files/bytes scanned.
- **Missing default branch:** show available refs and the configuration
  mismatch.
- **Missing ref/commit/path:** return repository-scoped `404` with a link to the
  current default Code page.

### Unexpected Failures

- Cache failure bypasses the cache and recomputes.
- A busy search limiter returns `429` with `Retry-After: 1`.
- A busy raw blob limiter returns `429` with `Retry-After: 1`; required inline
  blob pages return the sanitized `503`, while README degrades only its panel.
- A busy or timed-out required ref, summary, history, tree, or diff operation
  returns the sanitized `503` state rather than partial required data.
- A cooperatively time-bounded search or language scan returns a visibly
  truncated result. Limiter-busy/unexpected language failures and busy/timed-out
  disk-size analysis degrade only that optional panel and leave the rest of the
  page usable.
- Missing/corrupt/unreadable Git storage returns `503` with “Repository data
  unavailable.”
- Internal errors are logged with repository ID and request context.
- Responses never expose absolute storage paths, native errors, stack traces,
  or inspected internal terms.

## Security and Accessibility

- Authorization precedes all Git and filesystem reads.
- Ref and path resolution stays inside GitCore; web code never joins
  user-controlled segments onto the repository filesystem path.
- Repository metadata and search results are escaped.
- README HTML remains sanitized through MDEx.
- Raw filenames are safe for the Content-Disposition header.
- Active repository navigation uses `aria-current="page"`.
- Forms retain explicit labels and selected values.
- Copy feedback uses an accessible status region.
- All actions work from the keyboard and retain visible focus.
- Color is not the only carrier of visibility, errors, or selected state.
- Reduced-motion preferences remain respected.

## Verification Strategy

### Focused Automated Tests

Create scoped tests rather than expanding the current web catch-all file:

- `apps/git_core/test/repository_read_model_test.exs`
  - exact commit/branch/tag counts;
  - bounded ref samples and 100-ref branch/tag pagination;
  - canonical full refs, same-name branch/tag disambiguation, annotated-tag
    peeling, and legacy branch-first resolution;
  - all-parent merge counting and first-parent row-attribution semantics;
  - bounded 50-commit and 200-tree-row pagination;
  - refs containing `/`;
  - one-pass per-path history and directory semantics;
  - no rename-following behavior;
  - structured per-file diff lines/stats, the 1,000-file cap, and the
    200,000-byte shared limit;
  - deterministic path/content search ordering, typed file/byte/time/result
    truncation reasons, binary exclusion, and the 1 MiB blob cutoff;
  - complete and partial language totals plus disk-size timeout;
  - scan-limiter busy/permit behavior and typed errors;
  - prefix-bounded inline reads, complete-versus-truncated raw reads, and
    weighted blob-limiter behavior;
  - immutable cache hit/miss, entry/byte bounds, expiry, and fallback;
  - repack/GC disk-size changes are visible because disk usage is uncached.
- `apps/forge_repos/test/access_test.exs`
  - anonymous public read;
  - owner, organization, collaborator, and admin access;
  - private denial.
- `apps/fornacast_web/test/repository_controller_test.exs`
  - anonymous public and permitted private routes;
  - identical inaccessible/missing `404` behavior;
  - default and selected refs, directories, blobs, raw, commits, and search;
  - ref/commit/tree page validation and out-of-range behavior;
  - empty repository viewer/writer differences;
  - missing default/ref/commit/path and sanitized `503` behavior;
  - raw `413`, complete-body guarantee, safe filename encoding, and raster MIME
    allowlist;
  - commit detail diffs the URL SHA even when ref context points elsewhere;
  - `429` search/raw-busy behavior plus inline-blob, README, and optional-analysis
    degradation;
  - a push after snapshot resolution cannot mix old/new commit-derived data;
  - a later request resolves the pushed OID and uses a new immutable cache key.
- `apps/fornacast_web/test/repository_page_test.exs`
  - one resolved commit OID drives every snapshot-derived region;
  - no per-row native calls or tasks;
  - cache misses/failures preserve correctness;
  - GitCore failures map to typed page errors rather than inspected terms.
- `apps/fornacast_web/test/repository_html_test.exs`
  - DuskMoon component contracts;
  - active navigation and counts;
  - canonical full-ref-preserving links with short display labels;
  - anonymous brand/Login/Theme shell without authenticated controls;
  - ref-aware README link/image rewriting, non-raster fallback, and path-escape
    rejection;
  - absence of future/dead controls;
  - accessible labels, focusable controls, and status regions;
  - responsive class contracts and escaping.

Existing repository browser and Git transport tests continue to pass. Scoped
verification commands are:

```sh
mix test apps/git_core/test/repository_read_model_test.exs
mix test apps/forge_repos/test/access_test.exs
mix test apps/fornacast_web/test/repository_controller_test.exs
mix test apps/fornacast_web/test/repository_page_test.exs
mix test apps/fornacast_web/test/repository_html_test.exs
mix test apps/fornacast_web/test/fornacast_web_test.exs
mix assets.build
```

Format only touched Elixir files during implementation. If a test outside this
specification fails, report it and stop rather than expanding scope.

### Browser Verification

Use Chrome DevTools against real empty and populated repositories in sunshine
and moonlight themes at desktop and mobile widths. The verification server must
use the existing development entrypoint and listen on `0.0.0.0` so the remote
browser can reach it; use an available development port without changing the
production bind contract. Verify:

- public browsing in a fresh unauthenticated session;
- permitted private browsing and non-leaking denial;
- ref switching and slash-containing refs;
- root and nested commit-aware trees;
- path and content searches, no results, and truncated results;
- clone panel and copy success/failure feedback;
- README, blob, raw, diff, branch, tag, and commit pages;
- empty repository reader and writer states;
- keyboard navigation and visible focus;
- no failed assets, console errors, text overlap, or page-level horizontal
  overflow.
- generated CSS contains the PhoenixDuskmoon Git component styles, confirmed by
  computed styles rather than class names alone.

## Acceptance Criteria

The slice is complete only when:

1. Every visible control performs a real action; future controls are absent.
2. Public repository Code, commits, refs, source, raw, and search work without
   login.
3. Missing and inaccessible private repositories are indistinguishable.
4. One resolved snapshot OID drives every commit-derived region in each
   ref-backed response, even across a concurrent push. Commit detail instead
   resolves and diffs the SHA named by its URL; ref links are navigation context
   and a later request resolves them afresh.
5. Commit-aware tree rows are produced without N+1 history calls.
6. Counts, latest commits, paths, search results, languages, and size match the
   fixture repository.
7. Structured per-file diff data maps directly into `dm_git_commit_diff`.
8. Blob memory/backpressure, raw/search/analysis/cache limits, and fallback
   states are visible and tested.
9. DuskMoon Git components form the primary repository UI surface.
10. The clipboard workaround is marked with upstream issue `#80` and is absent
   once the dependency fix is adopted.
11. Focused tests and the asset build pass, followed by browser verification in
    both themes at 1,440 × 900, 768 × 1,024, and 390 × 844.

## Risks and Mitigations

- **Native scans become expensive:** use one native traversal per operation,
  dirty scheduling, hard ref/history/tree/diff/blob/search/analysis bounds, and
  immutable commit caches.
- **Mixed string/HEEx rendering becomes confusing:** confine HEEx conversion to
  `RepositoryHTML` and the repository shell variant; do not partially template
  unrelated controllers.
- **Cache state becomes correctness-critical:** keep it disposable and always
  fall back to bare-repository reads.
- **Full parity expands this slice:** hide unsupported tabs and keep later
  domains in separate specifications.
- **DuskMoon behavior is incomplete:** route confirmed dependency gaps upstream
  and mark only temporary, issue-linked workarounds.

## Follow-On Specifications

After this specification and its implementation plan are complete, create
separate design cycles for:

1. browser file editing and commit creation;
2. collaboration and social repository state;
3. Wiki, Projects, and cross-repository discovery;
4. Actions, Packages, Releases, and artifact storage.
