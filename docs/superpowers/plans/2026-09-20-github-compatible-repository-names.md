# GitHub-Compatible Repository Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Accept GitHub-compatible repository names, including `.github`, across local creation, REST creation, GitHub import, and metadata synchronization.

**Architecture:** Keep `ForgeRepos.Repository` as the local source of truth, widening its canonical slug rule to GitHub's documented 100-character ASCII set. Existing callers inherit the behavior; only the import-attempt persistence guard needs its duplicated length bound raised.

**Tech Stack:** Elixir 1.20, Ecto changesets, Phoenix/Plug, ExUnit, PostgreSQL 17

---

### Task 1: Prove the domain naming boundary

**Files:**
- Modify: `apps/forge_repos/test/forge_repos_test.exs:14`
- Modify: `apps/forge_repos/lib/forge_repos/repository.ex:8`

- [x] **Step 1: Write the failing domain regression**

Add these assertions to the existing slug test:

```elixir
assert Repository.normalize_slug(".GitHub") == ".github"

for canonical <- [
      ".github",
      "-leading",
      "trailing-",
      "trailing.",
      String.duplicate("a", 100)
    ] do
  assert Repository.canonical_slug?(canonical)
end

for noncanonical <- ["Demo", ".", "..", "demo.git", String.duplicate("a", 101)] do
  refute Repository.canonical_slug?(noncanonical)
end
```

Create the existing changeset fixture with `slug: ".github"` and assert that it is valid and retains `.github`.

- [x] **Step 2: Run the focused test and verify RED**

Run:

```sh
devenv shell -- env PGPORT=55432 mix test apps/forge_repos/test/forge_repos_test.exs:14
```

Expected: FAIL because the current rule rejects leading punctuation, trailing punctuation, and names longer than 63 characters.

- [x] **Step 3: Implement the canonical rule**

Use:

```elixir
@slug_regex ~r/^[a-z0-9._-]{1,100}$/
```

Remove `String.trim("-")` from `normalize_slug/1`, and remove the trailing-dot rejection from both `canonical_slug?/1` and `validate_slug/1`. Preserve the explicit `.`/`..` reservations and `.git` suffix behavior.

- [x] **Step 4: Run the focused test and verify GREEN**

Run the same line-focused command. Expected: PASS.

### Task 2: Prove every requested integration path

**Files:**
- Modify: `apps/fornacast_api/test/repositories_test.exs`
- Modify: `apps/forge_imports/test/discovery_test.exs`
- Modify: `apps/forge_repos/test/repository_metadata_sync_test.exs`
- Modify: `apps/forge_imports/test/import_persistence_hardening_test.exs:1020`
- Modify: `apps/forge_imports/lib/forge_imports/import_attempt.ex:174`

- [x] **Step 1: Add failing integration regressions**

Add an API test that posts `{"name": ".github", "auto_init": false}` to `/api/v3/user/repos`, asserts a 201 response with `name`, `full_name`, and clone URLs containing `.github`, then reads `/api/v3/repos/alice/.github` successfully.

Add a discovery test using source `duskmoon-dev/.github` and a repository fixture whose name is `.github`; assert `destination_slug == ".github"`, `state == :queued`, and `wait_reason == nil`.

Add a metadata-sync test that sets `input.remote.name` to `.github` and asserts the updated repository slug is `.github`.

Change the persistence assertions to accept `String.duplicate("a", 100)` and reject `String.duplicate("a", 101)`; remove `"demo."` from the invalid-decision list.

- [x] **Step 2: Run integration tests and verify RED**

Run:

```sh
devenv shell -- env PGPORT=55432 mix test \
  apps/fornacast_api/test/repositories_test.exs \
  apps/forge_imports/test/discovery_test.exs \
  apps/forge_repos/test/repository_metadata_sync_test.exs \
  apps/forge_imports/test/import_persistence_hardening_test.exs
```

Expected: the `.github` tests fail at local slug validation, and the 100-character import decision fails its old guard.

- [x] **Step 3: Widen import decision persistence**

Use:

```elixir
ForgeImports.SafeValue.github_source_text?(slug, 100, required?: true) and
  Repository.canonical_slug?(slug)
```

- [x] **Step 4: Run integration tests and verify GREEN**

Run the same four-file command. Expected: all tests pass.

### Task 3: Verify the scoped change

**Files:**
- Verify all files listed above plus the design and plan documents.

- [x] **Step 1: Format changed source and test files**

Run `devenv shell -- mix format`. Expected: command exits 0 and only planned files change.

- [x] **Step 2: Run the scoped PostgreSQL suite**

Run the four-file integration command from Task 2 plus `apps/forge_repos/test/forge_repos_test.exs`. Expected: all tests pass with zero failures.

- [x] **Step 3: Check formatting and diff hygiene**

Run:

```sh
devenv shell -- mix format --check-formatted
git diff --check
git status --short
```

Expected: both checks exit 0 and status lists only the planned files. Do not commit or push without separate user authorization.
