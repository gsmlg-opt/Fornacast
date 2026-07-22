# Fornacast Devenv PostgreSQL Testing Design

## Status

Approved in conversation on 2026-07-22.

## Context

Fornacast uses Turso for ordinary local development and supports PostgreSQL as a
second persistence adapter. The GitHub-compatible API foundation must be tested
against both adapters, but local PostgreSQL verification must not depend on a
Docker-managed database. The Backplane repository already provides the desired
development-environment pattern through devenv's managed PostgreSQL service.

This design adds that test-only service to Fornacast while preserving Turso as
the development default. It also makes both adapters mandatory in the existing
GitHub Actions test workflow.

## Goals

- Keep Turso as the default for `mix fornacast.run`, bare `mix test`, and normal
  local development.
- Provide a reproducible PostgreSQL 17 test service through devenv.
- Run the API and domain test suites against PostgreSQL without Docker commands,
  exposed ports, or a local database password.
- Preserve TCP-based PostgreSQL configuration for GitHub Actions and other
  external database services.
- Run the GitHub Actions test workflow once with Turso and once with PostgreSQL.
- Keep build caches separate for adapter-specific compilation and configuration.

## Non-goals

- Switching development from Turso to PostgreSQL.
- Starting Fornacast automatically as a devenv process.
- Replacing production Docker Compose or its PostgreSQL profile.
- Adding pgvector, Bun, Node, or another application dependency to the devenv
  PostgreSQL service.
- Changing release, E2E, or asset-build workflows as part of this slice.
- Hiding the PostgreSQL lifecycle behind a custom test wrapper.

## Local devenv boundary

The repository adds these checked-in files:

- `devenv.nix`: toolchain and PostgreSQL service definition;
- `devenv.yaml`: pinned rolling devenv modules and stable nixpkgs input; and
- `devenv.lock`: generated input lock.

An `.envrc` is intentionally omitted. Developers opt into the environment with
an explicit `devenv shell -- ...` command, and PostgreSQL starts only through
`devenv processes start postgres`.

`devenv.nix` uses the stable nixpkgs input and provides the project toolchain:

- Elixir on OTP 29;
- Git;
- Rust and Cargo for `git_core` native compilation;
- OpenSSL and `pkg-config`; and
- PostgreSQL 17.

The PostgreSQL service creates only `fornacast_test`. It does not create or own
`fornacast_dev`, because development remains Turso. The devenv configuration
must not set `FORNACAST_DATABASE_ADAPTER` globally.

The explicit local lifecycle is:

```sh
devenv processes start postgres
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  POSTGRES_TEST_DB=fornacast_test \
  mix test <scoped-paths> --max-cases 1
devenv processes stop
```

Commands run from the umbrella root. `devenv processes stop` is the cleanup
command; no Docker command participates in this path.

## PostgreSQL test configuration

The PostgreSQL branch in `config/test.exs` supports two connection forms:

1. When `PGHOST` is an absolute path, use it as Postgrex's `:socket_dir`. Read
   `PGUSER` and `PGPASSWORD`, with the current user as the username fallback.
   This is the devenv path and requires no exposed TCP port or password.
2. Otherwise, use TCP through `PGHOST` or `POSTGRES_HOST`, and read the port from
   `PGPORT` or `POSTGRES_PORT` with `5432` as the final default. Preserve
   `POSTGRES_USER` and `POSTGRES_PASSWORD` fallbacks for GitHub Actions.

Both forms continue to select the database through `POSTGRES_TEST_DB`, defaulting
to `fornacast_test`. Empty password values are omitted rather than converted into
invented credentials.

`config/config.exs` and `config/dev.exs` do not change. Consequently, the
development adapter remains the existing `FORNACAST_DATABASE_ADAPTER` default of
`turso`.

## API Sandbox initialization

`apps/fornacast_api/test/test_helper.exs` adopts the same conditional setup used
by the other database-backed applications:

```elixir
ExUnit.start()

if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
  Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, :manual)
end
```

This enables `FornacastAPI.ConnCase` to check out the configured Sandbox pool.
Turso behavior is unchanged.

## GitHub Actions adapter matrix

The existing `.github/workflows/test.yml` remains the single unit-test workflow.
Its unit job gains a matrix with `database_adapter: [turso, postgres]` and
`fail-fast: false`.

Each matrix job:

- sets `FORNACAST_DATABASE_ADAPTER` from the matrix value;
- includes the adapter name in its dependency-cache key;
- uses the same checked-in Mix and Cargo locks; and
- runs the existing full `mix test` command.

A PostgreSQL 17 service container is declared for the matrix job with fixed
test-only credentials and database `fornacast_test`. The service may also be
present during the Turso matrix entry; the explicit adapter selection proves
that Turso remains independent of PostgreSQL. A health check prevents the test
command from starting before PostgreSQL is ready.

The test-only service values are:

```text
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=fornacast_test
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
```

These are ephemeral CI credentials, not repository or deployment secrets.

## Failure behavior

- A missing or stopped local devenv PostgreSQL service produces a normal
  Postgrex connection failure; tests do not fall back silently to Turso.
- A failure in one GitHub Actions adapter entry does not cancel the other entry,
  preserving adapter-specific evidence.
- The PostgreSQL test helper selects manual Sandbox mode only for PostgreSQL and
  PostgreSQL aliases; it does not change Turso cleanup behavior.
- No PostgreSQL test command may mutate development Turso databases.

## Verification

The implementation is accepted when all of the following pass:

```sh
devenv shell -- true
devenv processes start postgres

devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  POSTGRES_TEST_DB=fornacast_test \
  mix test apps/fornacast_api/test/users_organizations_test.exs --max-cases 1

devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=turso \
  mix test apps/fornacast_api/test/users_organizations_test.exs --max-cases 1

devenv processes stop
mix format --check-formatted
git diff --check
```

Static workflow verification must additionally prove that the test matrix
contains exactly `turso` and `postgres`, uses `fail-fast: false`, separates cache
keys by adapter, and supplies a healthy PostgreSQL 17 service. The remote gate is
both matrix entries completing successfully in GitHub Actions.
