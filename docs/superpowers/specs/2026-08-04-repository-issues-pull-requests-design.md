# Repository Issues and Pull Requests Design

**Date:** 2026-08-04

**Status:** Approved

## Goal

Add working, repository-scoped Issues and Pull Requests to the Fornacast web UI
and expose the same resources through the supported GitHub-compatible REST API.
The web and API surfaces must share domain logic, persistence, authorization,
and Git operations.

This design builds on the approved GitHub-compatible API contract in
`2026-07-21-github-compatible-api-design.md` and its issue and pull-request
implementation plans. It adds the repository browser experience that those
documents anticipated but did not design.

## Scope

This slice includes:

- repository Issues and Pull Requests tabs with open counts;
- repository-scoped issue and pull-request lists;
- issue creation, editing, comments, close, and reopen;
- issue labels and assignees;
- pull-request creation from two branches in the same repository;
- pull-request conversation, commits, and changed-files views;
- pull-request close, reopen, mergeability, and merge-commit execution;
- GitHub-compatible REST resources for issues, issue comments, pull requests,
  and pull-request merges;
- public/private repository authorization and existence masking; and
- exact browser links from REST `html_url` fields after the web routes exist.

This slice excludes:

- GitHub synchronization, credentials, webhooks, imports, and mirroring;
- forks and cross-repository pull requests;
- reviews, approvals, review requests, and inline review comments;
- draft pull requests;
- squash and rebase merges;
- milestones, projects, reactions, notifications, and subscriptions; and
- global cross-repository issue or pull-request dashboards.

The existing authenticated `/issues` and `/pulls` workbench placeholders remain
outside this slice. They must not be presented as functional aggregate views.

## Architecture

The implementation uses one domain model behind two presentation surfaces:

```text
Repository web controllers         GitHub-compatible REST controllers
             |                                      |
             +-------------+------------------------+
                           |
                ForgeIssues / ForgePulls
                   |       |       |
              ForgeRepos   Repo   GitCore
              and Access  Audit   bounded Git I/O
```

`forge_issues` owns issue identities, the shared repository-local number
allocator, comments, repository labels, label assignments, and assignees.
`forge_pulls` owns pull-specific head/base identity, immutable analysis
snapshots, mergeability, merge results, and durable merge operations.

Every pull request has one canonical `ForgeIssues.Issue` row with kind
`pull_request`. Title, body, number, state, author, labels, assignees, comments,
and shared timestamps exist only on that row. `ForgePulls.PullRequest` does not
duplicate them. Consequently, issue-list API responses can contain pull
requests and expose the compatible `pull_request` link.

Both web and REST controllers call public context functions. They do not query
the database, authorize resources, manipulate Git objects, or coordinate merge
recovery directly. `forge_issues` does not depend on `forge_pulls`; the pull
domain composes issue operations inside caller-owned `Ecto.Multi` transactions.

## Persistence

The issue-domain migration adds:

- one repository-local number-counter row per repository;
- issues with repository, number, kind, author, title, body, state, state reason,
  and timestamps;
- issue comments;
- repository labels;
- issue-label join rows; and
- issue-assignee join rows.

The pull-domain migration adds:

- pull requests keyed uniquely by canonical issue identity;
- canonical head and base refs plus paired analyzed OIDs;
- mergeable state, merged timestamp, merging user, and merge commit SHA; and
- durable pull-merge operations with expected refs, candidate merge OID,
  progress state, lease, failure reason, and safe request metadata.

Repository issue numbers are allocated atomically inside the mutation
transaction. Ordinary issues and pull requests consume the same sequence. The
allocator must work with both Turso and PostgreSQL and must not use
`max(number) + 1`.

Deleting a repository cascades through its issue and pull resources. Issue and
comment authors use restricted user references, assignee membership is removed
with the deleted user, and nullable merge-operation actors use nilification.
This preserves authored history while allowing non-author relationships to be
cleaned up.

## Domain Behavior and Authorization

All operations resolve the repository before loading a nested issue, comment,
label, assignee, or pull request. Existing private-repository masking remains
in force: callers without repository-read access receive not-found behavior.

Permissions are:

- anonymous callers may read issues, pull requests, and comments in public
  repositories;
- authenticated repository readers may open issues, add comments, and open
  same-repository pull requests;
- resource authors may edit and close or reopen their own issues and pull
  requests, and edit or delete their own comments;
- repository writers and administrators may manage all repository issues,
  pull requests, labels, assignees, and comments; and
- only repository writers and administrators may merge pull requests.

`has_issues: false` prevents creation, listing, detail mutation, and comments on
ordinary issues. It does not disable pull requests, their canonical issue
identities, or their conversation comments.

Sensitive mutations append audit records in the same SQL transaction. Failed
validation, authorization, or audit insertion rolls back the entire mutation.

## Pull-Request Git Semantics

Only branches in the target repository are accepted. `head` may be spelled as
`branch` or `owner:branch`, but the owner must match the target repository
owner. Head and base must be different valid branch refs.

Each detail, comparison, mergeability, or merge operation resolves moving refs
once, then carries those immutable OIDs through the request. GitCore provides
bounded primitives for merge-base discovery, ahead/behind counts, commit-range
pagination, aggregate tree differences, conflict analysis, merge-tree
construction, merge-commit writing, and compare-and-swap ref updates.

Only `merge_method: "merge"` is accepted. A successful merge writes a genuine
two-parent commit whose first parent is the recorded base OID and whose second
parent is the recorded head OID. It never substitutes a direct fast-forward.

The merge runs inside the repository writer fence. It records a durable state
transition before and after Git mutations:

```text
prepared -> merge_written -> ref_advanced -> completed
```

Recovery may complete database and audit bookkeeping only when the current base
ref proves the recorded merge OID won. It must not create another merge commit
or advance an operation whose ref never moved. Ref races, conflicts, timeouts,
and bounded-scan failures remain diagnosable and never report a false success.

## GitHub-Compatible REST API

The supported API versions remain `2022-11-28` and `2026-03-10`. The issue and
pull slices implement these routes:

| Methods | Route | Behavior |
| --- | --- | --- |
| `GET`, `POST` | `/api/v3/repos/:owner/:repo/issues` | List or create issues |
| `GET`, `PATCH` | `/api/v3/repos/:owner/:repo/issues/:number` | Get or update an issue |
| `GET`, `POST` | `/api/v3/repos/:owner/:repo/issues/:number/comments` | List or create issue/PR conversation comments |
| `PATCH`, `DELETE` | `/api/v3/repos/:owner/:repo/issues/comments/:id` | Edit or delete a comment |
| `GET`, `POST` | `/api/v3/repos/:owner/:repo/pulls` | List or create pull requests |
| `GET`, `PATCH` | `/api/v3/repos/:owner/:repo/pulls/:number` | Get or update a pull request |
| `GET`, `PUT` | `/api/v3/repos/:owner/:repo/pulls/:number/merge` | Check or perform a merge |

Repository issue lists follow GitHub semantics and may include pull-backed
issue rows. Callers distinguish them by the `pull_request` field. Pull request
labels, assignees, and conversation comments remain issue resources.

Versioned validators, serializers, pruned OpenAPI artifacts, pagination links,
accepted fields, and exact status/error mappings remain governed by the
approved GitHub-compatible API design. Once browser detail routes exist,
`html_url` fields point to those browser routes rather than temporary API URLs.

## Repository Web Experience

Public browser routes are:

| Methods | Route | Page/action |
| --- | --- | --- |
| `GET` | `/:owner/:repo/issues` | Repository issue list |
| `GET` | `/:owner/:repo/issues/new` | New issue form |
| `POST` | `/:owner/:repo/issues` | Create issue |
| `GET` | `/:owner/:repo/issues/:number` | Issue conversation |
| `GET` | `/:owner/:repo/issues/:number/edit` | Edit issue form |
| `PATCH` | `/:owner/:repo/issues/:number` | Update issue |
| `POST` | `/:owner/:repo/issues/:number/comments` | Add comment |
| `PATCH` | `/:owner/:repo/issues/:number/state` | Close or reopen issue |
| `GET` | `/:owner/:repo/pulls` | Repository pull-request list |
| `GET` | `/:owner/:repo/pulls/new` | Compare branches and show pull-request form |
| `POST` | `/:owner/:repo/pulls` | Create pull request |
| `GET` | `/:owner/:repo/pulls/:number` | Pull-request conversation |
| `GET` | `/:owner/:repo/pulls/:number/commits` | Pull-request commits |
| `GET` | `/:owner/:repo/pulls/:number/files` | Pull-request changed files |
| `PATCH` | `/:owner/:repo/pulls/:number/state` | Close or reopen pull request |
| `POST` | `/:owner/:repo/pulls/:number/merge` | Merge pull request |

The exact mutation verbs may use Phoenix-compatible form overrides, but the
resulting route semantics remain non-GET and CSRF-protected.

`RepositoryHTML.repository_navigation/1` gains Issues and Pull Requests after
their routes and domains are operational. Each tab shows its open count and has
one active state. All pages render inside the existing repository frame so the
identity header, visibility, responsive navigation, and DuskMoon styling remain
consistent with Code, Commits, Branches, and Tags.

The browser issue list contains ordinary issues only; pull requests have their
own browser list even though the compatible REST issue list can contain both.
The issue page provides GitHub-familiar open/closed selection, query/filter
controls, label and assignee filters, sorting, pagination, and a
permission-aware New issue action. The detail page presents the title/state
header, metadata, body, chronological conversation, labels, assignees, edit
actions, comment form, and close/reopen action.

The pull list mirrors the issue list while identifying head and base branches.
The creation page validates and compares two branches before submission. Pull
detail has Conversation, Commits, and Files changed destinations. Conversation
shows the canonical issue body/comments and a merge box with current
mergeability, ref-race feedback, permission-aware controls, and the resulting
merge SHA when complete.

All user-authored Markdown uses the repository's established sanitization and
rendering boundary. Raw HTML from issue bodies, comments, commit messages, or
diffs is never marked safe without sanitization. Empty, disabled, forbidden,
conflicted, stale-ref, unavailable, and validation states have explicit
DuskMoon-rendered UI rather than generic crashes.

## Error Handling

Domain functions return tagged results. Presentation layers translate those
results without duplicating policy:

- missing or masked resources -> `404`;
- unauthenticated mutation -> sign-in flow on web, compatible auth error on API;
- authenticated but unauthorized mutation -> `403` where existence is already
  known;
- ordinary issue operation while issues are disabled -> `410`;
- invalid fields, branch identity, or unsupported feature -> `422`;
- changed required head or ref race -> `409`;
- merge conflict or disabled merge commits -> `405`; and
- exhausted bounded Git work or recovery unavailability -> `503`.

Web forms retain submitted safe values and render field errors. API errors use
the established version-aware error serializer and documentation links.
Neither surface logs credentials, tokens, private content, or unsanitized
request metadata.

## Verification

Verification stays scoped to touched applications until the final acceptance
flow.

Domain tests cover:

- atomic shared numbering under concurrency;
- issue, pull-request, comment, label, and assignee lifecycle;
- author, reader, writer, administrator, anonymous, and private masking rules;
- `has_issues` behavior; and
- mutation and audit rollback.

GitCore and pull-domain tests cover:

- bounded merge-base, commit-range, and aggregate diff behavior;
- merge conflicts and branch movement;
- genuine ordered two-parent merge commits;
- compare-and-swap races and writer-fence serialization; and
- recovery after every durable merge state.

REST tests cover both supported versions, OpenAPI completeness, exact response
fixtures, accepted and rejected fields, pagination and filters, PAT scopes,
status codes, public/private behavior, and issue/pull cross-representation.

Web tests cover route authorization, tab order/count/active state, lists,
forms, conversations, commits, files, merge controls, responsive repository
navigation, and every explicit error/empty state. Browser verification checks
the manifest-selected production asset and a real repository flow.

Final end-to-end acceptance:

1. create a repository and branches;
2. open an issue and a pull request through the REST API;
3. update and comment on them through the web UI;
4. inspect the PR conversation, commits, and files;
5. merge through the web UI;
6. fetch the same resources through both API versions; and
7. clone or fetch the repository and prove the base ref now points to the
   recorded two-parent merge commit.

## Success Criteria

The feature is complete when repository users can perform the included issue
and pull-request workflows from the web, compatible clients can perform the
same resource operations through `/api/v3`, web and API results remain
consistent, merge execution is race-safe and recoverable, and all scoped plus
end-to-end checks pass.
