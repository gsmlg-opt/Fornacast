# GitHub Metadata Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import GitHub identities, labels, issues, comments, assignees, and representable same-repository pull requests with exact source data, then open the guarded publication path and web start action.

**Architecture:** Existing domains gain narrow import changesets and `Ecto.Multi` contributors while `forge_imports` remains responsible for GitHub-specific mapping, representability, page ordering, checkpointing, and skip reports. Imported authors always retain a GitHub identity reference; presentation resolves a linked local user dynamically without rewriting history.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto 3.14, PostgreSQL 17, dormant compile-only Turso Ecto compatibility, Req 0.7, GitCore, Phoenix/PhoenixDuskmoon, versioned Fornacast REST serializers

---

**Prerequisite:** Complete `2026-08-25-github-repository-import.md` first.

**Design:** `docs/superpowers/specs/2026-08-25-github-repository-organization-import-design.md`

**Database acceptance boundary (2026-08-29):** PostgreSQL 17 is the required
domain database for all remaining implementation and release gates. Use
`FORNACAST_DATABASE_ADAPTER=postgres` with an isolated `MIX_BUILD_PATH` and
`PGPORT=55432` for every database-backed command. Turso Ecto support is dormant
compile-only compatibility: do not run it as milestone acceptance and do not
weaken migrations or tests for it. Historical completed Turso evidence below is
retained only as history; every remaining unchecked gate in this plan is
PostgreSQL-only.

**Milestone boundary:** This plan imports only current Fornacast capabilities. It does not add releases, milestones, reactions, reviews, cross-repository pull requests, drafts, projects, teams, or synchronization.

**Command convention:** Prefix Mix commands with:

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix <task-and-arguments>
```

Keep focused database suites serial with `--max-cases 1`.

## File and module map

- Attribution columns remain on issue/comment/assignee/pull tables; they do not create pseudo-users.
- `ForgeAccounts.ExternalAttribution`: safe presentation value for an unlinked GitHub identity.
- `ForgeIssues.Import`: exact-number/timestamp issue-domain `Ecto.Multi` contributors.
- `ForgePulls.Import`: exact immutable pull-specific `Ecto.Multi` contributor.
- `ForgeImports.GitHub.MetadataMapper`: pure GitHub payload normalization and skip classification.
- `ForgeImports.GitHub.MetadataImporter`: phase/page coordinator; checkpoint commits last in the same transaction.
- M1 `ObjectMapping`, `PageCheckpoint`, and `ReportEntry`: idempotency and complete accounting.

### Task 1: Add portable external-attribution columns and constraints

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260825000500_add_github_external_attribution.exs`
- Create: `apps/forge_issues/test/external_attribution_migration_test.exs`
- Modify: `apps/forge_issues/lib/forge_issues/issue.ex`
- Modify: `apps/forge_issues/lib/forge_issues/comment.ex`
- Modify: `apps/forge_issues/lib/forge_issues/issue_assignee.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/pull_request.ex`
- Modify: `apps/forge_issues/test/issue_domain_migration_test.exs`
- Modify: `apps/forge_pulls/test/forge_pulls_test.exs`

- [ ] **Step 1: Write migration tests before changing schemas**

Test that old local-author rows survive, GitHub-author rows insert, zero/two authored identities fail, zero/two assignee identities fail, and a merger has at most one identity.

```elixir
test "authored rows require exactly one local or GitHub identity" do
  assert_constraint(:issues, %{author_user_id: nil, author_github_identity_id: nil},
    "issues_author_identity_check"
  )

  assert_insertable(:issues, %{
    author_user_id: nil,
    author_github_identity_id: github_identity_id()
  })
end
```

- [ ] **Step 2: Run migration/schema tests and verify failure**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_issues/test/external_attribution_migration_test.exs apps/forge_issues/test/issue_domain_migration_test.exs --max-cases 1
```

Expected: FAIL because external columns do not exist.

- [ ] **Step 3: Add adapter-portable table changes**

Required shape:

```text
issues:          author_user_id nullable, author_github_identity_id nullable
issue_comments:  author_user_id nullable, author_github_identity_id nullable
issue_assignees: user_id nullable,        github_identity_id nullable
pull_requests:   merged_by_user_id nullable, merged_by_github_identity_id nullable
```

Use restricted foreign keys from authored history to `github_identities`. Add named checks:

```sql
(author_user_id IS NOT NULL) <> (author_github_identity_id IS NOT NULL)
(user_id IS NOT NULL) <> (github_identity_id IS NOT NULL)
NOT (merged_by_user_id IS NOT NULL AND merged_by_github_identity_id IS NOT NULL)
```

PostgreSQL uses ordinary alters/checks. Turso rebuilds each affected table while preserving every column, index, foreign key, existing row, and timestamp. Add external-ID indexes and unique `(issue_id, github_identity_id)` assignment index.

Update schemas with the new integer fields but leave ordinary local changesets unchanged.

- [ ] **Step 4: Run migrations and all affected schema suites**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix ecto.migrate
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_issues/test/external_attribution_migration_test.exs apps/forge_issues/test/issue_domain_migration_test.exs apps/forge_pulls/test/forge_pulls_test.exs --max-cases 1
```

Expected: all tests pass and ordinary issue/pull creation remains local-user based.

- [ ] **Step 5: Commit attribution persistence**

```bash
git add apps/fornacast/priv/repo/migrations/20260825000500_add_github_external_attribution.exs apps/forge_issues apps/forge_pulls
git commit -m "feat(collaboration): persist GitHub attribution"
```

### Task 2: Resolve linked and unlinked attribution without N+1 queries

**Files:**

- Create: `apps/forge_accounts/lib/forge_accounts/external_attribution.ex`
- Create: `apps/forge_accounts/test/github_attribution_test.exs`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`
- Modify: `apps/forge_issues/lib/forge_issues.ex`
- Modify: `apps/forge_issues/test/forge_issues_test.exs`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializer.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/pull.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/pull.ex`
- Modify: `apps/fornacast_api/test/issue_contract_test.exs`
- Modify: `apps/fornacast_api/test/pull_contract_test.exs`
- Modify: `apps/fornacast_web/test/issue_html_test.exs`
- Modify: `apps/fornacast_web/test/pull_request_html_test.exs`

- [ ] **Step 1: Write presentation/capability tests**

Prove an unlinked identity renders `Github:<login>`, ghost renders `Github:ghost`, linking switches presentation to the local `%User{}`, unlinking switches back, linked authors receive normal author capabilities only after repository-read authorization, and no link changes membership/collaborator/access state.

```elixir
assert %ForgeAccounts.ExternalAttribution{username: "Github:octocat"} =
         ForgeAccounts.resolve_attributions([{:github, identity.id}])[{:github, identity.id}]

assert %ForgeAccounts.User{id: actor.id} =
         ForgeAccounts.resolve_attributions([{:github, linked.id}])[{:github, linked.id}]
```

- [ ] **Step 2: Run tests and observe local-user-only assumptions**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_attribution_test.exs apps/forge_issues/test/forge_issues_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/pull_contract_test.exs --max-cases 1
```

Expected: FAIL where loaders/serializers expect only `author_user_id` and `%User{}`.

- [ ] **Step 3: Add batched attribution resolution and generic presentation**

Public API:

```elixir
resolve_attributions([{:user, id} | {:github, id}])
linked_user_id_for_github_identity(github_identity_id)
```

Safe external value:

```elixir
defmodule ForgeAccounts.ExternalAttribution do
  @enforce_keys [:github_identity_id, :username]
  defstruct [:github_identity_id, :username, :avatar_url, :profile_url]
end
```

Load all local users and GitHub identities/linked users in bounded batch queries. Update issue authors/comments/assignees and pull merger loading to carry tagged IDs. Derive author association only from a linked user's independent local role. Add virtual `merged_by` on `PullRequest` and serialize it in both API versions. Existing HEEx helpers continue to consume a value with `username`.

- [ ] **Step 4: Run the complete presentation matrix**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_attribution_test.exs apps/forge_issues/test/forge_issues_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/pull_contract_test.exs apps/fornacast_web/test/issue_html_test.exs apps/fornacast_web/test/pull_request_html_test.exs --max-cases 1
```

Expected: all tests pass with unchanged local-user fixtures.

- [ ] **Step 5: Commit attribution resolution**

```bash
git add apps/forge_accounts apps/forge_issues apps/fornacast_api apps/fornacast_web/test
git commit -m "feat(collaboration): resolve GitHub authors"
```

### Task 3: Add exact issue-domain import contributors

**Files:**

- Create: `apps/forge_issues/lib/forge_issues/import.ex`
- Create: `apps/forge_issues/test/github_import_test.exs`
- Modify: `apps/forge_issues/lib/forge_issues.ex`
- Modify: `apps/forge_issues/lib/forge_issues/issue.ex`
- Modify: `apps/forge_issues/lib/forge_issues/comment.ex`
- Modify: `apps/forge_issues/lib/forge_issues/label.ex`
- Modify: `apps/forge_issues/lib/forge_issues/issue_assignee.ex`
- Modify: `apps/forge_issues/lib/forge_issues/number_sequence.ex`

- [ ] **Step 1: Write exact-number/timestamp/import-replay tests**

Use sparse issue numbers 7 and 41. Assert exact source timestamps/state/closed time, GitHub author/comment/assignee, label normalization conflict returned explicitly, NUL/length/state errors, replay uniqueness, no sequence consumption during rows, and ordinary post-finalization issue number 42.

```elixir
multi =
  Ecto.Multi.new()
  |> ForgeIssues.import_identity_multi(:issue_41, repository, github_identity, :issue, %{
    number: 41,
    title: "Imported",
    body: "Body",
    state: :closed,
    closed_at: ~U[2025-01-03 00:00:00Z],
    inserted_at: ~U[2025-01-01 00:00:00Z],
    updated_at: ~U[2025-01-03 00:00:00Z]
  })
```

- [ ] **Step 2: Run and verify ordinary APIs cannot preserve source identity**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_issues/test/github_import_test.exs --max-cases 1
```

Expected: FAIL because import APIs/changesets are missing.

- [ ] **Step 3: Implement dedicated changesets and `Ecto.Multi` contributors**

Delegate from `ForgeIssues`:

```elixir
import_label_multi(multi, key, repository, attrs)
import_identity_multi(multi, key, repository, github_identity, kind, attrs)
import_comment_multi(multi, key, issue, github_identity, attrs)
import_issue_label_multi(multi, key, issue, label, attrs)
import_assignee_multi(multi, key, issue, github_identity, attrs)
finalize_import_sequence_multi(multi, key, repository)
```

`Issue.import_changeset/2` casts exact number/kind/title/body/state/reason, external author, `closed_at`, `inserted_at`, and `updated_at`; it does not call ordinary close-now normalization. `Comment.import_changeset/2` preserves source timestamps. Imported assignments always store `github_identity_id` even if linked. Finalization sets the sequence row to highest canonical number + 1 inside the caller transaction; later ordinary allocation still reads only that row.

- [ ] **Step 4: Run issue import and ordinary regression tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_issues/test/github_import_test.exs apps/forge_issues/test/forge_issues_test.exs apps/forge_issues/test/number_allocator_test.exs --max-cases 1
```

Expected: all tests pass and ordinary behavior is unchanged.

- [ ] **Step 5: Commit issue import APIs**

```bash
git add apps/forge_issues
git commit -m "feat(issues): import GitHub issue metadata"
```

### Task 4: Add exact pull-domain import contributors

**Files:**

- Create: `apps/forge_pulls/lib/forge_pulls/import.ex`
- Create: `apps/forge_pulls/test/github_import_test.exs`
- Modify: `apps/forge_pulls/lib/forge_pulls.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/pull_request.ex`

- [ ] **Step 1: Write merged/unmerged pull import tests**

Cover exact refs/SHAs/timestamps, coherent merged fields, external and ghost merger, wrong-repository canonical issue, non-pull canonical issue, invalid/distinct refs, and unchanged ordinary creation/update behavior.

```elixir
assert {:ok, %{pull: pull}} =
         Ecto.Multi.new()
         |> ForgePulls.import_pull_request_multi(
           :pull,
           repository,
           canonical_issue,
           github_merger,
           %{head_ref: "refs/heads/feature", base_ref: "refs/heads/main", head_sha: head, base_sha: base,
             merged_at: ~U[2025-02-03 00:00:00Z], merge_commit_sha: merge,
             inserted_at: ~U[2025-02-01 00:00:00Z], updated_at: ~U[2025-02-03 00:00:00Z]}
         )
         |> Repo.transaction()
```

- [ ] **Step 2: Run and verify import changeset is absent**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_pulls/test/github_import_test.exs --max-cases 1
```

Expected: FAIL with missing import function.

- [ ] **Step 3: Implement the pull import boundary**

Public contributor:

```elixir
import_pull_request_multi(multi, key, repository, canonical_issue, merger_identity_or_nil, attrs)
```

`PullRequest.import_changeset/2` preserves source fields/timestamps and enforces canonical distinct `refs/heads/*`, same hidden repository canonical issue of kind `:pull_request`, and coherent merged/unmerged fields. GitHub-specific draft/fork/live-ref classification remains outside this domain module.

- [ ] **Step 4: Run pull import and ordinary pull tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_pulls/test/github_import_test.exs apps/forge_pulls/test/forge_pulls_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit pull import APIs**

```bash
git add apps/forge_pulls
git commit -m "feat(pulls): import GitHub pull metadata"
```

### Task 5: Normalize GitHub payloads and classify unsupported objects

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/github/metadata_mapper.ex`
- Create: `apps/forge_imports/test/github/metadata_mapper_test.exs`
- Create: `apps/forge_imports/test/fixtures/github/labels_page.json`
- Create: `apps/forge_imports/test/fixtures/github/issues_page.json`
- Create: `apps/forge_imports/test/fixtures/github/comments_page.json`
- Create: `apps/forge_imports/test/fixtures/github/pull_same_repo.json`
- Create: `apps/forge_imports/test/fixtures/github/pull_cross_repo.json`

- [ ] **Step 1: Write pure mapper tests from fixed fixtures**

```elixir
assert {:ok, %{github_id: 301, number: 7, kind: :issue}} = MetadataMapper.issue(issue_payload)
assert {:skip, :cross_repository_pull, _details} = MetadataMapper.pull(cross_repo_payload, source_repository_id)
assert {:skip, :draft_pull, _details} = MetadataMapper.pull(draft_payload, source_repository_id)
```

Cover 64-bit IDs, timestamps, null/deleted actor to ghost, safe URLs, internal visibility warning, label fields, comment fields, same-repo PR, fork/cross-repo PR, draft, deleted branch, source-ref SHA mismatch, missing Git object, and unsupported feature summary.

- [ ] **Step 2: Run mapper tests before implementation**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github/metadata_mapper_test.exs --max-cases 1
```

Expected: FAIL with missing mapper.

- [ ] **Step 3: Implement a pure provider mapping API**

```elixir
label(payload)
issue(payload)
comment(payload)
pull(payload, github_repository_id, opts \\ [])
```

Every function returns `{:ok, normalized}`, `{:skip, stable_code, bounded_details}`, or `{:error, stable_code}`. Pull classification requires source head/base repository IDs to match, non-draft, live canonical branches whose staged refs equal observed SHAs, and all required objects after provider-ref pruning. Unsupported PRs never produce canonical issue input.

Emit category report data for milestones, reactions, locking, issue types, sub-issues, reviews, requested reviewers/teams, attachments, and other fetched unsupported fields without calling unsupported-only endpoints.

- [ ] **Step 4: Run mapper tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github/metadata_mapper_test.exs --max-cases 1
```

Expected: all mapper cases pass.

- [ ] **Step 5: Commit pure mapping**

```bash
git add apps/forge_imports/lib/forge_imports/github/metadata_mapper.ex apps/forge_imports/test/github/metadata_mapper_test.exs apps/forge_imports/test/fixtures/github
git commit -m "feat(import): map supported GitHub metadata"
```

### Task 6: Extend the GitHub client for supported metadata pages

**Files:**

- Modify: `apps/forge_imports/lib/forge_imports/github/client.ex`
- Modify: `apps/forge_imports/test/github/client_test.exs`

- [ ] **Step 1: Add failing endpoint/pagination tests**

Cover labels, all-state issues, issue comments, pull detail, assignee payloads embedded in issues, and no calls to releases/reviews/projects endpoints.

- [ ] **Step 2: Run the client suite and verify missing functions**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github/client_test.exs --max-cases 1
```

Expected: FAIL for missing metadata functions.

- [ ] **Step 3: Add the exact client surface**

```elixir
repository_labels(pat, owner, repository, opts \\ [])
repository_issues(pat, owner, repository, opts \\ [])
issue_comments(pat, owner, repository, issue_number, opts \\ [])
pull_request(pat, owner, repository, pull_number, opts \\ [])
```

Use `state=all`, `per_page=100`, validated Link pagination, the existing request gate, and existing response bounds/error classification. Do not add unsupported-only endpoint functions.

- [ ] **Step 4: Run the GitHub client suite**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github/client_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit client extensions**

```bash
git add apps/forge_imports/lib/forge_imports/github/client.ex apps/forge_imports/test/github/client_test.exs
git commit -m "feat(import): fetch supported GitHub metadata"
```

### Task 7: Commit each metadata page atomically and replay safely

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/github/metadata_importer.ex`
- Create: `apps/forge_imports/test/github/metadata_importer_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_worker.ex`
- Modify: `apps/forge_imports/lib/forge_imports/object_mapping.ex`
- Modify: `apps/forge_imports/lib/forge_imports/page_checkpoint.ex`
- Modify: `apps/forge_imports/lib/forge_imports/report_entry.ex`
- Modify: `apps/forge_imports/mix.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/review.html.heex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/show.html.heex`
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/test/repository_import_controller_test.exs`
- Modify: `apps/fornacast_web/test/import_html_test.exs`

- [ ] **Step 1: Write crash/replay/ordering acceptance tests**

Use a hidden repository with `main` and `feature` refs. Prove exact labels/issues/comments/assignees/one PR, `Github:ghost`, cross-repo/draft PR skips with no issue row, page replay no-op, rollback on forced checkpoint failure, no release/review-only requests, sequence finalization last, transition to `ready_to_publish` only after every phase checkpoint, and no visible repository before publication.

- [ ] **Step 2: Run and verify the worker publishes after Git only**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github/metadata_importer_test.exs --max-cases 1
```

Expected: FAIL because metadata phases/checkpoints are not implemented.

- [ ] **Step 3: Implement phase/page transactions**

Public API:

```elixir
ForgeImports.GitHub.MetadataImporter.stage(item, credential_checkout, opts \\ [])
ForgeImports.GitHub.MetadataImporter.stage_phase(item, phase, opts \\ [])
```

Phase order is:

```elixir
[:labels, :issues, :comments, :pull_requests, :number_sequence]
```

Add direct in-umbrella dependencies on `forge_issues` and `forge_pulls` to `apps/forge_imports/mix.exs`. For every REST page, one `Ecto.Multi` contains observed identities, domain rows/joins, object mappings, bounded report entries, count deltas, and the immutable page checkpoint last. Checkpoint failure rolls everything back. A committed checkpoint makes replay a no-op.

When mapped pull metadata references a Git object missing from the staged mirror, invoke `GitCore.Remote.refresh/3` once with the same credential, revalidate/prune the mirror, and reclassify the pull. A second miss becomes a bounded `source_drift` report/failure; it never loops.

Issue pages identify pull-backed entries and fetch/classify pull detail before inserting a canonical issue. Comments whose parent PR was skipped receive `parent_unsupported`. Pull-specific rows resolve the canonical issue through object mapping. Finalize the sequence only after every resource phase is terminal, then move to `ready_to_publish`.

Modify `RepositoryWorker` so `git_staged` transitions through `staging_metadata`; after every metadata phase and number-sequence checkpoint commits, it advances to `ready_to_publish` and invokes `RepositoryPublisher`. It never calls the publisher from `git_staged`.

Once that gate is active, add the web start route and action:

```elixir
post "/imports/:id/start", ImportController, :start
```

The review template renders the start form only for a fully resolved plan. The controller calls `ForgeImports.start_import/4`, redirects immediately to `/imports/:id`, and never performs Git or REST work in the request process.

- [ ] **Step 4: Run importer plus domain tests**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github/metadata_importer_test.exs apps/forge_issues/test/github_import_test.exs apps/forge_pulls/test/github_import_test.exs apps/fornacast_web/test/repository_import_controller_test.exs apps/fornacast_web/test/import_html_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit transactional metadata import**

```bash
git add apps/forge_imports apps/fornacast_web
git commit -m "feat(import): stage GitHub collaboration metadata"
```

### Task 8: Prove metadata import across presentation on PostgreSQL

**Files:**

- Create: `apps/forge_imports/test/github_metadata_import_integration_test.exs`
- Modify only files implicated by failing milestone acceptance tests.

- [ ] **Step 1: Add a published-repository acceptance test**

Prove one full hidden-to-published repository preserves numbers/timestamps/attribution, ordinary issue gets highest + 1, link/unlink changes attribution without access, unsupported PRs have report entries/no issue rows, no unsupported endpoints were called, and publication retains the shadow repository ID and staged metadata.

- [ ] **Step 2: Run the complete focused PostgreSQL suite serially**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_attribution_test.exs apps/forge_issues/test/external_attribution_migration_test.exs apps/forge_issues/test/github_import_test.exs apps/forge_pulls/test/github_import_test.exs apps/forge_imports/test/github/metadata_mapper_test.exs apps/forge_imports/test/github/metadata_importer_test.exs apps/forge_imports/test/github_metadata_import_integration_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/pull_contract_test.exs apps/fornacast_web/test/issue_html_test.exs apps/fornacast_web/test/pull_request_html_test.exs --max-cases 1
```

Expected: 0 failures.

- [ ] **Step 3: Run formatting and warnings-as-errors**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix format --check-formatted
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix compile --warnings-as-errors
```

Expected: both commands exit 0.

- [ ] **Step 4: Commit verification-only corrections**

```bash
git status --short
git diff --check
git add apps
git commit -m "test(import): verify GitHub metadata migration"
```

Do not create an empty commit when verification leaves the tree clean. Do not modify the public REST route manifest or OpenAPI operation set.
