# Repository Issues and Pull Requests Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add repository-scoped Issues and Pull Requests pages that share the completed GitHub-compatible domains, including conversations, branch comparison, commits, changed files, and merge controls.

**Architecture:** Complete the existing issue and pull domain/API plans first. Extend those domains with the read models required by server-rendered pages, then compose them through `RepositoryCollaborationPage`. Thin Phoenix controllers render DuskMoon HEEx views and translate tagged results without querying Ecto, reproducing authorization rules, or calling GitCore directly.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, HEEx, Ecto 3.14, Turso/PostgreSQL, Rustler/gix through GitCore, phoenix_duskmoon 9.8, MDEx, ExUnit, and live Chrome verification.

---

## Execution order

Execute these plans on the same branch in order:

1. `docs/superpowers/plans/2026-07-21-github-api-issues.md`
2. `docs/superpowers/plans/2026-07-21-github-api-pull-requests.md`
3. this plan

The first two plans own persistence, API serializers, OpenAPI contracts, the
merge state machine, and core merge primitives. This plan adds missing domain
read models and the repository browser.

## File structure

- `ForgeIssues` gains kind-correct paging, open counts, stable form options,
  and UI-neutral capabilities.
- `GitCore` and `ForgePulls` gain bounded immutable commit-range and aggregate
  diff reads, branch comparison, and fully loaded canonical issue views.
- `RepositoryCollaborationPage` composes domain values with the existing typed
  repository chrome.
- `RepositoryWeb` owns shared repository masking, response rendering, cache
  headers, and tagged error mapping for the three repository controllers.
- `CollaborationMarkdown` sanitizes issue/comment Markdown without README path
  rewriting.
- Dedicated Issue and Pull Request controllers remain HTTP adapters; their
  HEEx modules/templates own presentation only.

### Task 1: Add issue-domain browser queries

**Files:**
- Modify: `apps/forge_issues/lib/forge_issues.ex`
- Modify: `apps/forge_issues/lib/forge_issues/issue.ex`
- Modify: `apps/forge_issues/lib/forge_issues/comment.ex`
- Modify: `apps/forge_issues/test/forge_issues_test.exs`

- [ ] **Step 1: Write failing kind, count, option, and capability tests**

Create two ordinary issues and one pull-backed issue, close one ordinary issue,
then add these exact contract assertions:

```elixir
assert {:ok, %Fornacast.Page{entries: [%ForgeIssues.Issue{kind: :issue}], total: 1}} =
         ForgeIssues.list(reader, owner.username, repository.slug, %{
           kind: :issue,
           state: "open",
           page: 1,
           per_page: 30
         })

assert {:ok, %{issues: 1, pull_requests: 1}} =
         ForgeIssues.open_counts(reader, owner.username, repository.slug)

assert {:ok, %{labels: labels, assignees: assignees, capabilities: capabilities}} =
         ForgeIssues.form_options(writer, owner.username, repository.slug, nil)

assert Enum.map(labels, & &1.normalized_name) == Enum.sort(Enum.map(labels, & &1.normalized_name))
assert Enum.map(assignees, & &1.username) == Enum.sort(Enum.map(assignees, & &1.username))
assert capabilities.can_create
```

Also assert disabled ordinary issues produce a zero ordinary count while pull
count remains one; anonymous creation is false; authors can edit/comment/close
their own resource but cannot manage relationships; writers can manage all;
comment authors receive edit/delete capability.

- [ ] **Step 2: Verify the new issue interface is absent**

```bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
```

Expected: FAIL on `open_counts/3`, `form_options/4`, internal `kind` filtering,
and capability fields.

- [ ] **Step 3: Implement the browser-neutral issue contract**

Add:

```elixir
@type capabilities :: %{
        can_create: boolean(),
        can_comment: boolean(),
        can_edit: boolean(),
        can_close: boolean(),
        can_manage_relationships: boolean()
      }

@spec open_counts(User.t() | nil, String.t(), String.t()) ::
        {:ok, %{issues: non_neg_integer(), pull_requests: non_neg_integer()}} |
        {:error, error_reason()}

@spec form_options(User.t() | nil, String.t(), String.t(), Issue.t() | nil) ::
        {:ok, %{labels: [Label.t()], assignees: [User.t()], capabilities: capabilities()}} |
        {:error, error_reason()}
```

Extend only the normalized internal filter with
`kind: :issue | :pull_request | :all`; default to `:all` so REST behavior does
not change. Apply kind before count and pagination. Compute both open counts in
one grouped repository-scoped query. Return labels sorted by normalized name
and active eligible assignees sorted by username. Reuse the domain's existing
author/writer policy helpers for capabilities.

Add virtual `capabilities` maps to Issue and Comment and populate them in the
existing bounded loaders. Controllers and templates must not recalculate them.

- [ ] **Step 4: Run both adapter checks**

```bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
FORNACAST_DATABASE_ADAPTER=postgres mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
```

Expected: PASS twice.

- [ ] **Step 5: Commit**

```bash
git add apps/forge_issues/lib/forge_issues.ex apps/forge_issues/lib/forge_issues/issue.ex apps/forge_issues/lib/forge_issues/comment.ex apps/forge_issues/test/forge_issues_test.exs
git commit -m "feat(issues): expose repository browser queries"
```

### Task 2: Add immutable pull comparison reads

**Files:**
- Modify: `apps/git_core/lib/git_core.ex`
- Modify: `apps/git_core/lib/git_core/read_model.ex`
- Modify: `apps/git_core/lib/git_core/write_model.ex`
- Modify: `apps/git_core/lib/git_core/native.ex`
- Modify: `apps/git_core/native/fornacast_git_core/src/lib.rs`
- Modify: `apps/git_core/test/repository_write_model_test.exs`
- Create: `apps/forge_pulls/lib/forge_pulls/comparison.ex`
- Create: `apps/forge_pulls/lib/forge_pulls/changed_file_page.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/pull_request.ex`
- Modify: `apps/forge_pulls/test/forge_pulls_test.exs`

- [ ] **Step 1: Write failing GitCore commit-range and diff tests**

Build a head three commits ahead of base that changes two files and assert:

```elixir
assert {:ok, %GitCore.CommitPage{commits: commits, total: 3, page: 1}} =
         GitCore.commit_range_page(path, base_oid, head_oid, 1, per_page: 50)

assert Enum.map(commits, & &1.oid) == [head_oid, second_oid, first_oid]

assert {:ok, %GitCore.ComparisonDiff{files: files, changed_files: 2}} =
         GitCore.diff_between(path, base_oid, head_oid, page: 1, per_page: 100)

assert Enum.map(files, & &1.path) == ["lib/added.ex", "lib/changed.ex"]
```

Cover divergence, identical OIDs, invalid OIDs, pagination, deterministic
ordering, binary files, rename representation, limits, and deadline exhaustion.
Assert no refs or objects change.

- [ ] **Step 2: Verify missing GitCore functions**

```bash
mix test apps/git_core/test/repository_write_model_test.exs --only pull_compare --max-cases 1
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml pull_compare
```

Expected: FAIL on missing immutable comparison functions and bindings.

- [ ] **Step 3: Implement bounded immutable GitCore reads**

Expose:

```elixir
@spec commit_range_page(Path.t(), String.t(), String.t(), pos_integer(), keyword()) ::
        {:ok, GitCore.CommitPage.t()} | {:error, GitCore.Error.t()}

@spec diff_between(Path.t(), String.t(), String.t(), keyword()) ::
        {:ok, GitCore.ComparisonDiff.t()} | {:error, GitCore.Error.t()}
```

Both accept only OIDs, run under `ScanLimiter`, and share one absolute deadline.
Native code computes `base..head` and an aggregate tree diff, applies existing
scan/file/byte bounds, sorts files by path, and returns typed errors. It never
resolves refs, writes objects, or updates refs.

Define `GitCore.ComparisonDiff` in `read_model.ex` with enforced `files`,
`changed_files`, `additions`, `deletions`, and `truncated` fields. Reuse the
existing typed diff-file and line structs so commit and pull diff components
consume the same shape.

- [ ] **Step 4: Write failing ForgePulls browser-view tests**

```elixir
assert {:ok, branches} = ForgePulls.branch_options(repository, reader)
assert Enum.map(branches, & &1.name) == ["refs/heads/feature", "refs/heads/main"]

assert {:ok, %ForgePulls.Comparison{head_ref: "refs/heads/feature", base_ref: "refs/heads/main"}} =
         ForgePulls.compare(repository, reader, "feature", "main", [])

assert {:ok, %Fornacast.Page{entries: [_commit], total: 3}} =
         ForgePulls.list_commits(repository, pull, reader, page: 1, per_page: 50)

assert {:ok, %ForgePulls.ChangedFilePage{entries: [_first, _second], total: 2}} =
         ForgePulls.changed_files(repository, pull, reader, page: 1, per_page: 100)
```

Assert fully loaded pulls contain canonical Issue data and capability keys
`can_edit`, `can_close`, `can_comment`, and `can_merge`. Cover anonymous/public,
author, writer, closed, merged, conflicted, and moved-ref cases.

- [ ] **Step 5: Implement ForgePulls view contracts**

Create:

```elixir
defmodule ForgePulls.Comparison do
  @enforce_keys [:head_ref, :base_ref, :head_oid, :base_oid, :analysis]
  defstruct [:head_ref, :base_ref, :head_oid, :base_oid, :analysis]
end

defmodule ForgePulls.ChangedFilePage do
  @enforce_keys [:entries, :total, :page, :per_page, :truncated]
  defstruct [:entries, :total, :page, :per_page, :truncated]
end
```

Add `branch_options/2`, `compare/5`, `list_commits/4`, and `changed_files/4`.
Authorize repository read, resolve each moving ref once, and pass only OIDs to
GitCore. Pull loads populate virtual `issue`, `analysis`, and `capabilities`
fields. No controller calls GitCore or reconstructs canonical issue fields.

- [ ] **Step 6: Run focused pull/Git checks**

```bash
mix test apps/git_core/test/repository_write_model_test.exs --only pull_compare --max-cases 1
mix test apps/forge_pulls/test/forge_pulls_test.exs --max-cases 1
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml pull_compare
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/git_core apps/forge_pulls
git commit -m "feat(pulls): expose bounded comparison views"
```

### Task 3: Build shared repository collaboration chrome

**Files:**
- Modify: `apps/fornacast_web/mix.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/repository_page.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_html.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/repository_collaboration_page.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/repository_web.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/request_metadata.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/collaboration_markdown.ex`
- Create: `apps/fornacast_web/test/repository_collaboration_page_test.exs`
- Create: `apps/fornacast_web/test/collaboration_markdown_test.exs`
- Modify: `apps/fornacast_web/test/repository_html_test.exs`
- Modify: `apps/fornacast_web/test/repository_controller_test.exs`

- [ ] **Step 1: Write failing chrome, navigation, and Markdown tests**

Assert every repository page has exactly one active tab in the approved order:
Code, Commits, Branches, Tags, Issues, Pull Requests. Assert both collaboration
links and counts, graceful omission of unavailable counts, and absence of
branch/ref controls on issue/pull page kinds.

Lock user Markdown safety:

```elixir
safe =
  CollaborationMarkdown.render(
    "[ok](https://example.test) <script>x()</script> ![x](javascript:x)"
  )

html = safe |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
assert html =~ ~s(href="https://example.test")
refute html =~ "<script"
refute html =~ "javascript:"
refute html =~ "/src/"
```

Assert `RequestMetadata.from_conn/1` returns only request ID, normalized IP,
and bounded user agent; it must not contain cookies, sessions, CSRF, bodies,
or tokens.

- [ ] **Step 2: Verify shared modules and tabs are absent**

```bash
mix test apps/fornacast_web/test/repository_collaboration_page_test.exs apps/fornacast_web/test/collaboration_markdown_test.exs apps/fornacast_web/test/repository_html_test.exs --max-cases 1
```

Expected: FAIL on missing modules and navigation items.

- [ ] **Step 3: Implement shared page/request boundaries**

Add `forge_issues` and `forge_pulls` dependencies to `fornacast_web`. Extend
`RepositoryPage.Chrome` with
`collaboration_counts: %{issues: nil, pull_requests: nil}`. Add
`RepositoryPage.collaboration/5`, returning this existing typed shape:

```elixir
%RepositoryPage.Result{kind: kind, chrome: chrome, content: content}
```

Allow kinds `:issues`, `:issue`, `:pulls`, `:pull`, `:pull_commits`, and
`:pull_files`. The function performs only bounded ref-summary and clone/header
composition. `RepositoryCollaborationPage` adds `ForgeIssues.open_counts/3`.
Existing repository pages keep rendering if count loading fails, with nil
counts.

Expose this composition interface before controller work begins:

```elixir
@spec issues(Repository.t(), User.t(), User.t() | nil, map(), keyword()) :: result()
@spec issue(Repository.t(), User.t(), User.t() | nil, pos_integer(), keyword()) :: result()
@spec pulls(Repository.t(), User.t(), User.t() | nil, map(), keyword()) :: result()
@spec pull(Repository.t(), User.t(), User.t() | nil, pos_integer(), keyword()) :: result()
@spec pull_commits(Repository.t(), User.t(), User.t() | nil, pos_integer(), map()) :: result()
@spec pull_files(Repository.t(), User.t(), User.t() | nil, pos_integer(), map()) :: result()

@type result :: {:ok, %RepositoryPage.Result{}} | {:error, term()}
```

The second argument is the repository owner account. Keyword options select
fake domain/Git modules in tests; production defaults use the real contexts.

Implement `RepositoryWeb.fetch/3`, `render/4`, and `error/3`. This seam masks
private repositories, loads the owner, renders safe HEEx through
`HTML.repository_page/3`, applies `private, no-store`, and maps domain errors to
404/403/410/422/409/405/503. Controllers do not copy those rules.

- [ ] **Step 4: Implement sanitized Markdown and navigation**

`CollaborationMarkdown.render/1` parses with MDEx, allows only http, https, and
mailto links, rejects protocol-relative links, sanitizes with
`MDEx.Document.default_sanitize_options/0`, and only then calls
`Phoenix.HTML.raw/1`. It performs no path/ref rewriting.

Append Issues and Pull Requests to `dm_git_repository_nav`, reading counts from
Chrome. Replace the ref-control condition with:

```elixir
@result.kind in [:tree, :blob, :commits, :commit, :search]
```

Add exact path helpers for all approved issue and pull routes. Decorate existing
RepositoryController results before rendering.

- [ ] **Step 5: Run shared web tests**

```bash
mix test apps/fornacast_web/test/repository_collaboration_page_test.exs apps/fornacast_web/test/collaboration_markdown_test.exs apps/fornacast_web/test/repository_html_test.exs apps/fornacast_web/test/repository_controller_test.exs --max-cases 1
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/fornacast_web/mix.exs apps/fornacast_web/lib/fornacast_web/repository_page.ex apps/fornacast_web/lib/fornacast_web/repository_collaboration_page.ex apps/fornacast_web/lib/fornacast_web/repository_web.ex apps/fornacast_web/lib/fornacast_web/request_metadata.ex apps/fornacast_web/lib/fornacast_web/collaboration_markdown.ex apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/repository_html.ex apps/fornacast_web/test/repository_collaboration_page_test.exs apps/fornacast_web/test/collaboration_markdown_test.exs apps/fornacast_web/test/repository_html_test.exs apps/fornacast_web/test/repository_controller_test.exs
git commit -m "feat(web): add repository collaboration chrome"
```

### Task 4: Add issue lists and conversations

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/issue_controller.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/issue_html.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/issue_html/index.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/issue_html/show.html.heex`
- Create: `apps/fornacast_web/test/issue_controller_test.exs`
- Create: `apps/fornacast_web/test/issue_html_test.exs`

- [ ] **Step 1: Write failing read tests**

Cover public anonymous list/detail, private anonymous 404, ordinary-issue-only
paging, state/label/assignee/creator/sort/direction filters, preserved query
pagination, disabled issues 410, empty state, sanitized body/comments, counts,
and one active Issues tab. Use a fake collaboration page module following the
existing RepositoryController test seam.

- [ ] **Step 2: Verify routes and controller are absent**

```bash
mix test apps/fornacast_web/test/issue_controller_test.exs apps/fornacast_web/test/issue_html_test.exs --max-cases 1
```

Expected: FAIL with missing issue controller/routes.

- [ ] **Step 3: Add public read routes and thin actions**

Place static routes before `:number` in the final browser scope:

```elixir
get "/:owner/:repo/issues", IssueController, :index
get "/:owner/:repo/issues/:number", IssueController, :show
```

`index/2` validates positive pages and allowlisted filters before calling
`RepositoryCollaborationPage.issues/5`. `show/2` parses a positive number and
calls `issue/5`, which loads the issue and chronological comments through
ForgeIssues. Invalid pages/numbers return 404; invalid filters return 422 with
safe values retained. A pull-backed canonical issue redirects to its Pull
Request detail route, preserving the separate browser lists.

- [ ] **Step 4: Implement DuskMoon list and conversation templates**

Render inside `<RepositoryHTML.repository_frame result={@result}
active={:issues}>`. Use `dm_input`, `dm_select`, `dm_badge`, semantic links, and
server pagination. The list contains ordinary issues only. Conversation cards
render through CollaborationMarkdown and action visibility comes only from
domain capabilities. Add hooks `data-issues-page`, `data-issue-filters`,
`data-issue-row`, and `data-issue-conversation`.

- [ ] **Step 5: Run issue read tests**

```bash
mix test apps/fornacast_web/test/issue_controller_test.exs apps/fornacast_web/test/issue_html_test.exs --max-cases 1
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/fornacast_web/lib/fornacast_web/router.ex apps/fornacast_web/lib/fornacast_web/controllers/issue_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/issue_html.ex apps/fornacast_web/lib/fornacast_web/controllers/issue_html apps/fornacast_web/test/issue_controller_test.exs apps/fornacast_web/test/issue_html_test.exs
git commit -m "feat(web): add repository issue pages"
```

### Task 5: Add issue forms and mutations

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/issue_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/issue_html.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/issue_html/new.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/issue_html/edit.html.heex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/issue_html/show.html.heex`
- Modify: `apps/fornacast_web/test/issue_controller_test.exs`
- Modify: `apps/fornacast_web/test/issue_html_test.exs`

- [ ] **Step 1: Write failing mutation tests**

Cover sign-in redirects with return targets, CSRF, reader creation/comment,
author edit/close/reopen, writer label/assignee management, forbidden mutation,
disabled issues, field-level 422 values, PRG, and absence of relationship
controls for non-writer authors.

- [ ] **Step 2: Add mutation routes and authentication**

```elixir
post "/:owner/:repo/issues", IssueController, :create
patch "/:owner/:repo/issues/:number", IssueController, :update
post "/:owner/:repo/issues/:number/comments", IssueController, :comment
patch "/:owner/:repo/issues/:number/comments/:id", IssueController, :update_comment
delete "/:owner/:repo/issues/:number/comments/:id", IssueController, :delete_comment
patch "/:owner/:repo/issues/:number/state", IssueController, :state
```

Add GET routes for `/issues/new` and `/issues/:number/edit` before the generic
number route. Apply RequireUser only to `new`, `edit`, and mutations. Each mutation passes
`RequestMetadata.from_conn(conn)` to one ForgeIssues operation and redirects
after success. Load canonical kind before commenting so pull-backed comments
redirect to the Pull Request conversation.

- [ ] **Step 3: Implement forms and error projection**

Use `dm_input` for title, `dm_textarea` for body/comment, and `dm_select` for
labels/assignees. PATCH forms use POST with CSRF and hidden `_method=patch`.
Map domain validation by field and place resource errors in `dm_alert`. Never
log or put issue/comment content in URLs.

- [ ] **Step 4: Run mutation tests**

```bash
mix test apps/fornacast_web/test/issue_controller_test.exs apps/fornacast_web/test/issue_html_test.exs --max-cases 1
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast_web/lib/fornacast_web/router.ex apps/fornacast_web/lib/fornacast_web/controllers/issue_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/issue_html.ex apps/fornacast_web/lib/fornacast_web/controllers/issue_html apps/fornacast_web/test/issue_controller_test.exs apps/fornacast_web/test/issue_html_test.exs
git commit -m "feat(web): add repository issue workflows"
```

### Task 6: Add pull list, comparison, and creation

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_controller.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html/index.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html/new.html.heex`
- Create: `apps/fornacast_web/test/pull_request_controller_test.exs`
- Create: `apps/fornacast_web/test/pull_request_html_test.exs`

- [ ] **Step 1: Write failing list/creation tests**

Cover public and private reads, state/head/base/sort/direction filters,
pagination, branch ordering, default base, same-owner prefix, invalid/equal refs,
comparison counts, conflict preview, retained 422 values, reader creation,
unauthenticated redirect, and PRG to detail.

- [ ] **Step 2: Add exact routes and thin actions**

```elixir
get "/:owner/:repo/pulls", PullRequestController, :index
get "/:owner/:repo/pulls/new", PullRequestController, :new
post "/:owner/:repo/pulls", PullRequestController, :create
```

`new/2` passes optional head/base strings to ForgePulls.compare; blank values
show branch options without comparison. `create/2` calls only
`create_pull_request/4` with safe request metadata. No controller resolves refs
or calls GitCore.

- [ ] **Step 3: Implement DuskMoon list and compare/create views**

Render with `active={:pulls}`. The list shows state plus head/base metadata. The
form uses two `dm_select` branch fields and shows ahead/behind/commit/file counts
from Comparison. Show conflicts with `dm_alert` and one primary Create action.
Add `data-pulls-page` and `data-pull-compare`.

- [ ] **Step 4: Run pull list/creation tests**

```bash
mix test apps/fornacast_web/test/pull_request_controller_test.exs apps/fornacast_web/test/pull_request_html_test.exs --max-cases 1
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast_web/lib/fornacast_web/router.ex apps/fornacast_web/lib/fornacast_web/controllers/pull_request_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html.ex apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html apps/fornacast_web/test/pull_request_controller_test.exs apps/fornacast_web/test/pull_request_html_test.exs
git commit -m "feat(web): add pull request creation"
```

### Task 7: Add pull conversation, commits, files, state, and merge

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html/show.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html/commits.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html/files.html.heex`
- Modify: `apps/fornacast_web/test/pull_request_controller_test.exs`
- Modify: `apps/fornacast_web/test/pull_request_html_test.exs`

- [ ] **Step 1: Write failing detail and mutation tests**

Cover canonical issue body/comments, Conversation/Commits/Files navigation,
commit pagination, aggregate diff stats/truncation, binary files, escaped
commit/diff text, author close/reopen, writer-only merge, conflict or disabled
merge 405, head/ref race 409, unavailable 503, merged SHA, closed/already
merged controls, CSRF, and PRG.

- [ ] **Step 2: Add detail and mutation routes**

```elixir
get "/:owner/:repo/pulls/:number/commits", PullRequestController, :commits
get "/:owner/:repo/pulls/:number/files", PullRequestController, :files
get "/:owner/:repo/pulls/:number", PullRequestController, :show
patch "/:owner/:repo/pulls/:number/state", PullRequestController, :state
post "/:owner/:repo/pulls/:number/merge", PullRequestController, :merge
```

Place static suffixes before the generic number route. Reads call ForgePulls
through the page composer. State calls `update_pull_request/5`; merge calls
`merge/5` with optional expected head and only `merge_method: "merge"`.
Conversation comments use the canonical issue-comment route from Task 5.

- [ ] **Step 3: Implement detail views**

Conversation renders canonical Issue content, branch identity, analysis, and a
`data-merge-box` section; it reads `can_merge` only from domain capabilities.
Commits use `dm_table`. Files use `dm_git_commit_diff` with each typed changed
file mapped exactly like the existing repository commit template: path, status,
additions, deletions, binary, truncated, and escaped line maps. Provide
accessible subnavigation with one current item and hooks
`data-pull-conversation`, `data-pull-commits`, and `data-pull-files`.

- [ ] **Step 4: Run pull detail and merge tests**

```bash
mix test apps/fornacast_web/test/pull_request_controller_test.exs apps/fornacast_web/test/pull_request_html_test.exs apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast_web/lib/fornacast_web/router.ex apps/fornacast_web/lib/fornacast_web/controllers/pull_request_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html.ex apps/fornacast_web/lib/fornacast_web/controllers/pull_request_html apps/fornacast_web/test/pull_request_controller_test.exs apps/fornacast_web/test/pull_request_html_test.exs
git commit -m "feat(web): add pull request workflows"
```

### Task 8: Link REST resources to browser pages

**Files:**
- Modify: `apps/fornacast_api/lib/fornacast_api/url.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/issue.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/issue_comment.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/pull.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/issue.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/issue_comment.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/pull.ex`
- Modify: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue.json`
- Modify: `apps/fornacast_api/test/fixtures/2022-11-28/issues/pull-issue.json`
- Modify: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-list.json`
- Modify: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-comment.json`
- Modify: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-comment-list.json`
- Modify: `apps/fornacast_api/test/fixtures/2022-11-28/pulls/pull.json`
- Modify: `apps/fornacast_api/test/fixtures/2022-11-28/pulls/pull-list.json`
- Modify: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue.json`
- Modify: `apps/fornacast_api/test/fixtures/2026-03-10/issues/pull-issue.json`
- Modify: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-list.json`
- Modify: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-comment.json`
- Modify: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-comment-list.json`
- Modify: `apps/fornacast_api/test/fixtures/2026-03-10/pulls/pull.json`
- Modify: `apps/fornacast_api/test/fixtures/2026-03-10/pulls/pull-list.json`
- Modify: `apps/fornacast_api/test/issue_contract_test.exs`
- Modify: `apps/fornacast_api/test/pull_contract_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/html.ex`
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Write failing cross-surface URL tests**

Assert issue `html_url` equals `https://forge.test/alice/demo/issues/7` and
pull `html_url` equals `https://forge.test/alice/demo/pulls/8`; both resolve to
matching HTML. Assert API `url`, comments URL, and pull link remain API URLs.
Lock both supported version fixtures.

- [ ] **Step 2: Add explicit browser URL functions**

```elixir
@spec issue_web(String.t(), String.t(), pos_integer()) :: String.t()
@spec issue_comment_web(
        String.t(),
        String.t(),
        :issue | :pull_request,
        pos_integer(),
        pos_integer()
      ) :: String.t()
@spec pull_web(String.t(), String.t(), pos_integer()) :: String.t()
```

Percent-encode owner/repository segments through the existing URL helper. Use
these only for `html_url` and HTML link relations. Comment links use the
canonical issue kind to select `/issues/:number#issuecomment-:id` or
`/pulls/:number#issuecomment-:id`. Update only the listed literal fixtures and
let contract tests validate every changed document against its pinned schema.

- [ ] **Step 3: Remove misleading global links**

Remove `/issues` and `/pulls` from authenticated app/repository shell primary
navigation. Keep placeholder routes unchanged because global dashboards remain
out of scope.

- [ ] **Step 4: Run API and shell tests**

```bash
mix test apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/pull_contract_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast_api apps/fornacast_web/lib/fornacast_web/html.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(api): link issues and pulls to web pages"
```

### Task 9: Finish responsive styling and acceptance verification

**Files:**
- Modify: `apps/fornacast_web/assets/css/app.css`
- Modify: `apps/fornacast_web/test/issue_html_test.exs`
- Modify: `apps/fornacast_web/test/pull_request_html_test.exs`
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`
- Create: `apps/fornacast_web/test/issues_pulls_workflow_test.exs`
- Modify: `scripts/e2e-smoke.sh`

- [ ] **Step 1: Add failing structural and workflow checks**

Assert stable hooks, one primary action per page, labeled forms, keyboard
subnavigation, state text independent of color, local long-diff scrolling, and
no page overflow. The database-backed workflow creates branches, opens issue
and pull through API, comments through web, merges through web, fetches both API
versions, and verifies base ref plus ordered merge parents with GitCore and
`git cat-file -p`.

- [ ] **Step 2: Add minimum scoped DuskMoon CSS**

Use theme tokens under `[data-repository-page]` for collaboration grids,
conversation spacing, filters, merge box, pull subnav, and diff overflow. Stack
forms/actions at 640px and preserve tab scrolling at 768px. Add no hard-coded
colors, DaisyUI, or second component library.

- [ ] **Step 3: Run formatting, scoped tests, and assets**

```bash
mix format --check-formatted apps/forge_issues apps/forge_pulls apps/git_core apps/fornacast_api apps/fornacast_web
mix test apps/forge_issues/test apps/forge_pulls/test apps/git_core/test/repository_write_model_test.exs apps/fornacast_api/test/issue_controller_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/pull_controller_test.exs apps/fornacast_api/test/pull_contract_test.exs apps/fornacast_web/test --max-cases 1
mix assets.deploy
```

Expected: all commands PASS and the digest manifest is updated.

- [ ] **Step 4: Verify the manifest-selected UI in Chrome**

Use isolated data and fresh anonymous, reader, author, writer, and denied
sessions. Verify all issue and pull flows in sunshine/moonlight at 1440x900,
768x1024, and 390x844. At every viewport assert:

```javascript
document.documentElement.scrollWidth <= document.documentElement.clientWidth
```

Also check tab-local scrolling, keyboard focus, reduced motion, computed
DuskMoon styles, hit targets, console/network errors, and that loaded CSS/JS
URLs are exactly those selected by the digest manifest.

- [ ] **Step 5: Run end-to-end smoke and inspect state**

```bash
mix test apps/fornacast_web/test/issues_pulls_workflow_test.exs --max-cases 1
scripts/e2e-smoke.sh
git status --short
git diff --check
```

Expected: workflow/smoke PASS, only intended changes remain, and diff check is
clean.

- [ ] **Step 6: Commit**

```bash
git add apps/fornacast_web/assets/css/app.css apps/fornacast_web/test apps/fornacast_api/test apps/forge_issues/test apps/forge_pulls/test apps/git_core/test scripts/e2e-smoke.sh
git commit -m "test(web): verify issue and pull workflows"
```

## Completion checklist

- [ ] Existing issue and pull plans are complete with scoped checks passing.
- [ ] Repository tabs, pages, forms, conversations, commits, files, and merge
  work in real browser sessions.
- [ ] Web and both REST versions expose consistent state and browser URLs.
- [ ] No synchronization, dashboards, reviews, forks, drafts, squash/rebase,
  milestones, projects, reactions, or notifications were added.
- [ ] Scoped tests, asset deployment, browser checks, and E2E smoke pass without
  unrelated changes.
