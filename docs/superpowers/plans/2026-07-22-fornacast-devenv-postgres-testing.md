# Fornacast Devenv PostgreSQL Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Fornacast development on Turso while adding a test-only devenv PostgreSQL service and running the GitHub Actions unit suite against both adapters.

**Architecture:** Devenv owns a local PostgreSQL 17 service and exposes it through the standard `PGHOST` Unix-socket contract, but it never selects the Fornacast database adapter globally. Test configuration translates either devenv socket variables or CI TCP variables into Ecto repository options, and the existing GitHub Actions test job runs an adapter-keyed matrix with a healthy PostgreSQL service.

**Tech Stack:** devenv 2.1, Nix, Elixir 1.20 on OTP 29, Ecto 3.14, PostgreSQL 17, Turso/ex_turso, ExUnit, and GitHub Actions.

---

**Approved specification:** `docs/superpowers/specs/2026-07-22-fornacast-devenv-postgres-testing-design.md`

## Scope and execution guardrails

- Keep `FORNACAST_DATABASE_ADAPTER` unset in devenv so development continues to default to Turso.
- Create only the `fornacast_test` PostgreSQL database. Do not add a PostgreSQL development database or a Fornacast application process.
- Do not add `.envrc`, pgvector, Bun, Node, or asset-build configuration.
- Do not modify Docker, Compose, release, CI-build, or E2E files. The asset-build path remains blocked by `duskmoon-dev/phoenix-duskmoon-ui#104` and is not part of this plan.
- Preserve both PostgreSQL connection styles: Unix sockets from devenv and TCP from GitHub Actions or an external database.
- Run database-backed tests serially with `--max-cases 1`.
- Stop the devenv process manager with `devenv processes down` after each live verification session.
- Format only touched Elixir files. If an out-of-scope test fails, record it and stop rather than widening this slice.

## File map

- Create `devenv.yaml`: pin devenv's rolling modules and the stable nixpkgs release used for toolchain packages.
- Create `devenv.nix`: provide the Elixir/Rust build tools and a test-only PostgreSQL 17 service.
- Create `devenv.lock`: generated lock for the declared inputs.
- Modify `.gitignore`: ignore generated devenv state and the conventional Nix result symlink.
- Modify `config/test.exs`: translate devenv socket variables or CI TCP variables into Postgrex options.
- Modify `apps/fornacast_api/test/test_helper.exs`: put the PostgreSQL Sandbox into manual mode before `ConnCase` checkouts.
- Create `apps/fornacast_api/test/database_workflow_contract_test.exs`: pin the dual-adapter GitHub Actions contract.
- Modify `.github/workflows/test.yml`: run Turso and PostgreSQL matrix entries with adapter-specific caches.

### Task 1: Add the pinned test-only devenv PostgreSQL service

**Files:**
- Modify: `.gitignore`
- Create: `devenv.yaml`
- Create: `devenv.nix`
- Create: `devenv.lock`

- [ ] **Step 1: Run the structural check and verify the environment is absent**

Run:

```bash
test -f devenv.nix && test -f devenv.yaml
```

Expected: exit `1` because neither checked-in devenv definition exists.

- [ ] **Step 2: Ignore generated devenv and Nix state**

Append this block to `.gitignore`:

```gitignore
# devenv
.devenv/
.devenv.*
/result
```

- [ ] **Step 3: Add the pinned input definition**

Create `devenv.yaml` with exactly:

```yaml
# yaml-language-server: $schema=https://devenv.sh/devenv.schema.json
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
  nixpkgs-stable:
    url: github:nixos/nixpkgs/release-26.05

allowUnfree: true
```

- [ ] **Step 4: Add the toolchain and PostgreSQL service**

Create `devenv.nix` with exactly:

```nix
{
  pkgs,
  lib,
  inputs,
  ...
}: let
  pkgs-stable = import inputs.nixpkgs-stable {system = pkgs.stdenv.system;};
in {
  env.ELIXIR_ERL_OPTIONS = "+B";

  packages = with pkgs-stable;
    [
      git
      pkg-config
      openssl
      cargo
      rustc
    ]
    ++ lib.optionals stdenv.isLinux [
      inotify-tools
    ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam29Packages.elixir_1_20;

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
    port = 55432;
    listen_addresses = "";
    initialDatabases = [
      {name = "fornacast_test";}
    ];
  };
}
```

Do not add `env.FORNACAST_DATABASE_ADAPTER`, `processes.fornacast`, or a `fornacast_dev` database. Port `55432` identifies the project-specific Unix socket; the empty listen address prevents TCP exposure.

- [ ] **Step 5: Evaluate the environment and generate the lock**

Run:

```bash
devenv shell -- true
```

Expected: exit `0`, `devenv.lock` is created, and evaluation finds `beam29Packages.elixir_1_20` plus `postgresql_17` in the stable input. If online input resolution is slow, the checked-in Backplane lock may be reused only after confirming its declared input graph is identical; the plain shell command must still pass against that lock without changing a pin.

- [ ] **Step 6: Prove the service definition is test-only**

Run:

```bash
devenv eval services.postgres.enable
devenv eval services.postgres.port
devenv eval services.postgres.listen_addresses
devenv shell -- env \
  -u FORNACAST_DATABASE_ADAPTER \
  MIX_ENV=dev \
  MIX_BUILD_PATH=_build/devenv-turso \
  mix run --no-start -e '
  "turso" = Application.fetch_env!(:fornacast, :database_adapter)
'
```

Expected: the eval commands print `true`, `55432`, and `""`; the shell command exits `0`, proving the service is deterministic and does not switch development away from Turso.

- [ ] **Step 7: Check and commit the environment definition**

Run:

```bash
nix-instantiate --parse devenv.nix >/dev/null
git diff --check
git add .gitignore devenv.nix devenv.yaml devenv.lock
git commit -m "chore(devenv): add postgres test service"
```

Expected: Nix parsing and the whitespace check pass; the commit contains only `.gitignore` and the three devenv files.

### Task 2: Support devenv sockets and CI TCP connections in test config

**Files:**
- Modify: `config/test.exs:7-21`

- [ ] **Step 1: Run a socket-config probe and verify it fails**

Run:

```bash
devenv shell -- env \
  MIX_ENV=test \
  MIX_BUILD_PATH=_build/test-postgres \
  FORNACAST_DATABASE_ADAPTER=postgres \
  PGHOST=/tmp/fornacast-postgres-socket \
  PGPORT=55432 \
  PGUSER=fornacast_socket_user \
  PGPASSWORD= \
  POSTGRES_TEST_DB=fornacast_socket_test \
  mix run --no-start -e '
    config = Application.fetch_env!(:fornacast, Fornacast.Repo)
    "/tmp/fornacast-postgres-socket" = config[:socket_dir]
    "fornacast_socket_user" = config[:username]
    "fornacast_socket_test" = config[:database]
    nil = config[:password]
    nil = config[:hostname]
    55432 = config[:port]
  '
```

Expected: non-zero exit with a match failure because the current configuration has no `:socket_dir` and still uses the old `POSTGRES_*`-only username lookup.

- [ ] **Step 2: Implement explicit socket-or-TCP configuration**

Replace the PostgreSQL branch in `config/test.exs` with:

```elixir
    value when value in ["postgres", "postgresql"] ->
      username =
        System.get_env("PGUSER") ||
          System.get_env("POSTGRES_USER") ||
          System.get_env("USER", "postgres")

      password =
        case System.get_env("PGPASSWORD") || System.get_env("POSTGRES_PASSWORD") do
          value when value in [nil, ""] -> nil
          value -> value
        end

      host = System.get_env("PGHOST") || System.get_env("POSTGRES_HOST", "localhost")

      port =
        System.get_env("PGPORT") ||
          System.get_env("POSTGRES_PORT", "5432")

      port = String.to_integer(port)

      connection =
        if Path.type(host) == :absolute do
          [hostname: nil, port: port, socket_dir: host]
        else
          [hostname: host, port: port, socket_dir: nil]
        end

      credentials =
        [
          username: username,
          password: password,
          database: System.get_env("POSTGRES_TEST_DB", "fornacast_test")
        ]

      credentials ++ connection
```

Do not modify the Turso branch or any non-test configuration.

- [ ] **Step 3: Re-run the socket probe and verify it passes**

Run the exact Step 1 command again.

Expected: exit `0`; `:socket_dir`, port, username, and database match, the empty password is normalized to `nil`, and the base TCP hostname is cleared.

- [ ] **Step 4: Run a TCP-config probe**

Run:

```bash
devenv shell -- env \
  -u PGHOST \
  -u PGUSER \
  -u PGPASSWORD \
  -u PGPORT \
  MIX_ENV=test \
  MIX_BUILD_PATH=_build/test-postgres \
  FORNACAST_DATABASE_ADAPTER=postgres \
  POSTGRES_HOST=127.0.0.1 \
  POSTGRES_PORT=55432 \
  POSTGRES_USER=fornacast_ci \
  POSTGRES_PASSWORD=ci-password \
  POSTGRES_TEST_DB=fornacast_ci_test \
  mix run --no-start -e '
    config = Application.fetch_env!(:fornacast, Fornacast.Repo)
    "127.0.0.1" = config[:hostname]
    55432 = config[:port]
    "fornacast_ci" = config[:username]
    "ci-password" = config[:password]
    "fornacast_ci_test" = config[:database]
    nil = config[:socket_dir]
  '
```

Expected: exit `0`, proving the GitHub Actions TCP fallback remains available.

- [ ] **Step 5: Format and commit the test configuration**

Run:

```bash
mix format config/test.exs
mix format --check-formatted config/test.exs
git diff --check
git add config/test.exs
git commit -m "test(db): support postgres socket connections"
```

Expected: formatting and whitespace checks pass; the commit changes only `config/test.exs`.

### Task 3: Initialize the API PostgreSQL Sandbox

**Files:**
- Modify: `apps/fornacast_api/test/test_helper.exs:1`

- [ ] **Step 1: Start the devenv PostgreSQL service**

Run:

```bash
devenv processes up -d --strict-ports postgres
devenv processes wait --timeout 120
devenv processes list
devenv shell -- env | rg '^PG(HOST|PORT)='
devenv shell -- psql -v ON_ERROR_STOP=1 -d fornacast_test -c 'select 1'
```

Expected: `postgres` reports as running, the readiness wait exits `0`, the shell reports its project socket and `PGPORT=55432`, and the query proves `fornacast_test` exists from the service definition.

- [ ] **Step 2: Verify the API helper has not selected manual Sandbox mode**

Run:

```bash
rg -n 'Sandbox\.mode\(Fornacast\.Repo, :manual\)' \
  apps/fornacast_api/test/test_helper.exs
```

Expected: exit `1` because the API helper currently leaves PostgreSQL's Sandbox in its default `:auto` mode. A focused API test alone is not a valid red check here because an explicit checkout can still succeed while the pool remains in `:auto` mode.

- [ ] **Step 3: Add the established manual Sandbox initialization**

Set `apps/fornacast_api/test/test_helper.exs` to exactly:

```elixir
ExUnit.start()

if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
  Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, :manual)
end
```

- [ ] **Step 4: Re-run PostgreSQL and Turso focused tests**

Run:

```bash
devenv shell -- env \
  MIX_BUILD_PATH=_build/test-postgres \
  FORNACAST_DATABASE_ADAPTER=postgres \
  POSTGRES_TEST_DB=fornacast_test \
  mix test apps/fornacast_api/test/users_organizations_test.exs --max-cases 1

devenv shell -- env \
  MIX_BUILD_PATH=_build/test-turso \
  FORNACAST_DATABASE_ADAPTER=turso \
  FORNACAST_TEST_DATABASE_PATH=/tmp/fornacast-devenv-turso-test.db \
  mix test apps/fornacast_api/test/users_organizations_test.exs --max-cases 1
```

Expected: both commands pass with the same test count and zero failures.

- [ ] **Step 5: Stop the test service**

Run:

```bash
devenv processes down
devenv processes list
```

Expected: `down` exits `0`; `list` reports that no process manager is running, and no worktree devenv process remains.

- [ ] **Step 6: Format and commit the Sandbox setup**

Run:

```bash
mix format apps/fornacast_api/test/test_helper.exs
mix format --check-formatted apps/fornacast_api/test/test_helper.exs
git diff --check
git add apps/fornacast_api/test/test_helper.exs
git commit -m "test(api): support postgres sandbox"
```

Expected: the commit contains only the API test helper.

### Task 4: Run the GitHub Actions test suite against both adapters

**Files:**
- Create: `apps/fornacast_api/test/database_workflow_contract_test.exs`
- Modify: `.github/workflows/test.yml:14-63`

- [ ] **Step 1: Write the failing workflow contract**

Create `apps/fornacast_api/test/database_workflow_contract_test.exs` with exactly:

```elixir
defmodule FornacastAPI.DatabaseWorkflowContractTest do
  use ExUnit.Case, async: true

  @workflow Path.expand("../../../.github/workflows/test.yml", __DIR__)

  test "unit tests run against Turso and PostgreSQL with isolated caches" do
    workflow = File.read!(@workflow)

    assert workflow =~ "fail-fast: false"
    assert workflow =~
             ~r/database_adapter:\s*\n\s*- turso\s*\n\s*- postgres\s*\n\s*env:/

    assert workflow =~
             ~s(FORNACAST_DATABASE_ADAPTER: ${{ matrix.database_adapter }})

    assert workflow =~
             ~r/key:.*\$\{\{ matrix\.database_adapter \}\}.*hashFiles/s

    assert workflow =~
             ~r/restore-keys:\s*\|\s*\n\s*\$\{\{ runner\.os \}\}-test-\$\{\{ matrix\.database_adapter \}\}-\$\{\{ env\.MIX_ENV \}\}-/
  end

  test "the matrix has a healthy PostgreSQL 17 test service" do
    workflow = File.read!(@workflow)

    assert workflow =~ "image: postgres:17"
    assert workflow =~ "POSTGRES_DB: fornacast_test"
    assert workflow =~ "POSTGRES_USER: postgres"
    assert workflow =~ "POSTGRES_PASSWORD: postgres"
    assert workflow =~ ~r/ports:\s*\n\s*- 5432:5432/
    assert workflow =~ "pg_isready -U postgres -d fornacast_test"
    assert workflow =~ "--health-retries 5"
  end
end
```

- [ ] **Step 2: Run the contract and verify it fails**

Run:

```bash
devenv shell -- env \
  MIX_BUILD_PATH=_build/test-turso \
  FORNACAST_DATABASE_ADAPTER=turso \
  FORNACAST_TEST_DATABASE_PATH=/tmp/fornacast-workflow-contract-red.db \
  mix test apps/fornacast_api/test/database_workflow_contract_test.exs --max-cases 1
```

Expected: FAIL because the workflow still pins Turso globally and has no matrix or PostgreSQL service.

- [ ] **Step 3: Add the adapter matrix and PostgreSQL service**

In `.github/workflows/test.yml`, keep the existing global toolchain variables but remove the global `FORNACAST_DATABASE_ADAPTER: turso`. Replace the `unit` job header with:

```yaml
  unit:
    name: Unit Tests (${{ matrix.database_adapter }})
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        database_adapter:
          - turso
          - postgres
    env:
      FORNACAST_DATABASE_ADAPTER: ${{ matrix.database_adapter }}
      POSTGRES_HOST: localhost
      POSTGRES_PORT: 5432
      POSTGRES_DB: fornacast_test
      POSTGRES_TEST_DB: fornacast_test
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_DB: fornacast_test
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres -d fornacast_test"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
```

Retain every existing step. Change the cache key and restore prefix to exactly:

```yaml
          key: ${{ runner.os }}-test-${{ matrix.database_adapter }}-${{ env.MIX_ENV }}-${{ hashFiles('mix.lock', 'apps/git_core/native/fornacast_git_core/Cargo.lock') }}
          restore-keys: |
            ${{ runner.os }}-test-${{ matrix.database_adapter }}-${{ env.MIX_ENV }}-
```

The PostgreSQL service intentionally exists in both matrix entries. Explicit adapter selection proves the Turso entry remains independent of the available PostgreSQL server.

- [ ] **Step 4: Re-run the workflow contract**

Run:

```bash
devenv shell -- env \
  MIX_BUILD_PATH=_build/test-turso \
  FORNACAST_DATABASE_ADAPTER=turso \
  FORNACAST_TEST_DATABASE_PATH=/tmp/fornacast-workflow-contract-green.db \
  mix test apps/fornacast_api/test/database_workflow_contract_test.exs --max-cases 1
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Inspect and commit the workflow unit**

Run:

```bash
git diff --check
git diff -- .github/workflows/test.yml apps/fornacast_api/test/database_workflow_contract_test.exs
git add .github/workflows/test.yml apps/fornacast_api/test/database_workflow_contract_test.exs
git commit -m "ci(github): update github actions workflows"
```

Expected: the commit contains only the test workflow and its contract test. Do not push.

### Task 5: Verify the complete dual-adapter testing slice

**Files:**
- Verify only; no planned file changes.

- [ ] **Step 1: Verify devenv evaluation and the Turso development default**

Run:

```bash
devenv shell -- true
devenv shell -- env \
  -u FORNACAST_DATABASE_ADAPTER \
  MIX_ENV=dev \
  MIX_BUILD_PATH=_build/devenv-turso \
  mix run --no-start -e '
  "turso" = Application.fetch_env!(:fornacast, :database_adapter)
'
```

Expected: both commands exit `0`.

- [ ] **Step 2: Run the focused PostgreSQL gate**

Run:

```bash
devenv processes up -d --strict-ports postgres
devenv processes wait --timeout 120
devenv shell -- env | rg '^PG(HOST|PORT)='
devenv shell -- psql -v ON_ERROR_STOP=1 -d fornacast_test -c 'select 1'
devenv shell -- env \
  MIX_BUILD_PATH=_build/test-postgres \
  FORNACAST_DATABASE_ADAPTER=postgres \
  POSTGRES_TEST_DB=fornacast_test \
  mix test \
    apps/forge_accounts/test \
    apps/forge_repos/test \
    apps/fornacast_api/test/users_organizations_test.exs \
    apps/fornacast_api/test/repositories_test.exs \
    --max-cases 1
```

Expected: all scoped domain and API tests pass against PostgreSQL with zero failures.

- [ ] **Step 3: Run the corresponding Turso gate**

Run:

```bash
devenv shell -- env \
  MIX_BUILD_PATH=_build/test-turso \
  FORNACAST_DATABASE_ADAPTER=turso \
  FORNACAST_TEST_DATABASE_PATH=/tmp/fornacast-devenv-final-turso.db \
  mix test \
    apps/forge_accounts/test \
    apps/forge_repos/test \
    apps/fornacast_api/test/users_organizations_test.exs \
    apps/fornacast_api/test/repositories_test.exs \
    apps/fornacast_api/test/database_workflow_contract_test.exs \
    --max-cases 1
```

Expected: all corresponding tests plus the workflow contract pass against Turso with zero failures.

- [ ] **Step 4: Stop devenv services even if a test failed**

Run:

```bash
devenv processes down
devenv processes list
```

Expected: `down` exits `0`; `list` reports that no process manager is running, and no worktree devenv process remains.

- [ ] **Step 5: Run final format, compile, secret, and diff checks**

Run:

```bash
devenv shell -- mix format --check-formatted \
  config/test.exs \
  apps/fornacast_api/test/test_helper.exs \
  apps/fornacast_api/test/database_workflow_contract_test.exs
devenv shell -- env \
  -u FORNACAST_DATABASE_ADAPTER \
  MIX_ENV=dev \
  MIX_BUILD_PATH=_build/verify-turso \
  mix compile --warnings-as-errors
rg -n 'FORNACAST_DATABASE_ADAPTER\s*=\s*postgres|env\.FORNACAST_DATABASE_ADAPTER' devenv.nix devenv.yaml
git diff --check
git status --short --branch
```

Expected: formatting and compilation pass, the search returns no global PostgreSQL adapter selection, no whitespace errors exist, and the worktree is clean apart from deliberately preserved state outside this plan.

## Slice acceptance checklist

- [ ] Bare development continues to select Turso.
- [ ] Devenv provides PostgreSQL 17 and creates only `fornacast_test`.
- [ ] Local PostgreSQL tests use devenv and never invoke Docker.
- [ ] PostgreSQL test configuration accepts devenv Unix sockets and CI TCP connections.
- [ ] API `ConnCase` can check out a manual PostgreSQL Sandbox.
- [ ] The GitHub Actions unit job runs Turso and PostgreSQL entries with `fail-fast: false`.
- [ ] Adapter names partition GitHub Actions build caches.
- [ ] Both local adapter gates pass and devenv services stop cleanly.
