# PostgreSQL-First Database Boundary

**Date:** 2026-08-29

**Status:** Approved design, pending written-spec review

## Context

Fornacast currently selects its Ecto adapter at compile time and defaults to
ExTurso/Turso in development, tests, Docker, CI, E2E, and published releases.
PostgreSQL 17 is already supported by the schemas, migrations, test sandbox,
devenv service, and CI matrix, but operators must opt in and published GHCR
images are compiled for Turso.

The GitHub-import cleanup journal has now exceeded Turso's supported expression
depth. ExTurso 3.0.2 exits the BEAM while evaluating its large JSON `CHECK`;
ExTurso 3.0.4 contains the crash but rejects the migration with
`Expression tree is too large (maximum depth 100)`. The 3.0.4 family also retains
the optimizer-eliminated parameter regression tracked by
[`gsmlg-dev/concord#77`](https://github.com/gsmlg-dev/concord/issues/77).

The product boundary is therefore changing: PostgreSQL is the supported domain
database for development, testing, and production. The Turso Ecto adapter remains
in source as dormant compile-only compatibility, but the current full schema is
not installable on it and it does not gate features or releases.

## Decision

- `Fornacast.Repo` defaults to PostgreSQL in every environment.
- Official development, test, CI, Docker, E2E, release, and production paths use
  PostgreSQL.
- The published GHCR image is compiled for PostgreSQL and requires exactly one
  complete PostgreSQL connection mode at runtime.
- The compile-time Turso Ecto path remains in source, but receives no release
  runtime claim and no required CI matrix until it can install the full schema.
- Concord's separate embedded Turso/VSR configuration store remains unchanged.
- The Concord, ExTurso, and ViewstampedReplication family remains pinned at 3.0.2
  until its independent compatibility blockers are resolved.
- GitHub-import cleanup acceptance is PostgreSQL-only. No Turso-specific
  constraint weakening, SQL rewriting, or partial migration is permitted.

## Storage boundaries

The decision separates two database roles that currently share the word
"Turso":

### Authoritative domain database

`Fornacast.Repo` owns users, organizations, repositories, collaborators, GitHub
identities and credentials, imports, cleanup journals, issues, pull requests,
release metadata, leases, recovery markers, authorization data, and audit events.
This database is PostgreSQL for every supported environment.

### Embedded infrastructure metadata

Concord continues to own app-level key/value configuration and LocalCAS metadata
coordination using its existing embedded Turso/VSR roots. It is not an Ecto
adapter for Fornacast domain data, does not evaluate the GitHub-import cleanup
constraint, and remains part of the local cold-recovery set.

Bare Git repositories, SSH state, and LocalCAS release-asset bytes remain on
their existing filesystem boundaries. PostgreSQL does not absorb byte storage.

## Compile-time adapter contract

Adapter selection remains compile-time because `Fornacast.Repo` uses
`Application.compile_env/3`.

- Omitted `FORNACAST_DATABASE_ADAPTER` means `postgres`.
- `postgres` and `postgresql` select `Ecto.Adapters.Postgres`.
- `turso` and `libsql` continue to select `Ecto.Adapters.Turso` only for an
  explicit source build.
- Unsupported values fail compilation with the existing explicit error.
- Runtime configuration must match the compiled adapter. A PostgreSQL image
  cannot be switched to Turso by changing an environment variable after build.
- `Fornacast.Repo`'s compile-time fallback changes from Turso to PostgreSQL so a
  missing application entry cannot silently restore the old default.

Both `postgrex` and `ex_turso` remain dependencies. ExTurso is still required by
the optional Ecto build and is also part of the Concord package family; changing
the default does not justify dependency removal or an unrelated upgrade.

PostgreSQL 17 is the only supported production major for this release. Other
majors may work but are outside the tested operator contract until separately
qualified.

## Development configuration

PostgreSQL 17 in `devenv.nix` becomes the standard local database. The normal
development path starts the managed PostgreSQL service before running Fornacast.
The service provisions both `fornacast_dev` and `fornacast_test`; a fresh
checkout must not depend on an implicit user-named database.

Development connection configuration must accept standard PostgreSQL variables
first:

- `PGUSER` / `POSTGRES_USER`
- `PGPASSWORD` / `POSTGRES_PASSWORD`
- `PGHOST` / `POSTGRES_HOST`
- `PGPORT` / `POSTGRES_PORT`
- `PGDATABASE` / `POSTGRES_DB`

An absolute `PGHOST` is treated as a Unix socket directory, matching test
configuration and devenv's socket-only PostgreSQL service. A non-absolute host
uses TCP. The default database is `fornacast_dev`.

Developer documentation must make process readiness and database setup explicit:

```sh
devenv processes up postgres -d
devenv shell -- mix ecto.setup
devenv shell -- mix fornacast.run
```

Equivalent locally managed PostgreSQL installations remain supported through the
same environment variables.

## Test configuration and CI

Tests default to PostgreSQL with `Ecto.Adapters.SQL.Sandbox`. Existing
PostgreSQL-aware test helpers remain the canonical isolation path.

Required GitHub Actions change from a Turso/PostgreSQL matrix to one PostgreSQL
job:

- PostgreSQL 17 service with a health check;
- `FORNACAST_DATABASE_ADAPTER=postgres` in format, build, test, E2E, and release
  jobs;
- adapter-qualified caches retained where compile artifacts may differ; and
- database workflow contract tests updated to require PostgreSQL rather than two
  mandatory adapters.

Turso is removed from required pull-request and release gates. No permanently
failing compatibility job is added. A future manual or scheduled compatibility
workflow may be introduced after Turso can install the full schema, but it is not
part of this milestone.

Turso-specific source and tests remain in the tree. An explicit Turso build may
run tests that do not install the full application schema, but the umbrella
runtime and migration suite are known incompatible until `concord#90` is fixed.
They do not weaken PostgreSQL coverage or conditionally bypass the cleanup
journal.

## Production PostgreSQL connection contract

An actual release command accepts exactly one of two mutually exclusive modes:

1. **URL mode:** nonempty `DATABASE_URL`, with no `POSTGRES_HOST`,
   `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, or `POSTGRES_PASSWORD` in the
   app environment.
2. **Component mode:** nonempty `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`,
   and `POSTGRES_PASSWORD`, optional `POSTGRES_PORT` defaulting to `5432`, and no
   `DATABASE_URL`.

Supplying both modes, a partial component mode, or an invalid port fails before
the Repo starts. Component mode passes the password to Postgres as an exact value,
not through URI interpolation, so reserved URI characters require no special
encoding. URL mode remains available for hosted PostgreSQL providers and follows
normal URI percent-encoding rules.

## Docker and production

The Dockerfile build argument and runtime image default change to PostgreSQL. The
published release image is built once for PostgreSQL.

Docker Compose changes are structural:

- PostgreSQL is a default service, not an optional profile.
- The app builds and runs with `FORNACAST_DATABASE_ADAPTER=postgres`.
- `.env` is the single source of `POSTGRES_DB`, `POSTGRES_USER`, and
  `POSTGRES_PASSWORD` for both the app and database containers.
- The app uses component mode with `POSTGRES_HOST=db` and `POSTGRES_PORT=5432`;
  default Compose does not synthesize or set `DATABASE_URL`.
- The app waits for the database health check before starting.
- PostgreSQL data stays in `postgres-data`.
- `fornacast-data` continues to hold bare repositories, SSH state, the Concord
  config database/VSR data, and release-asset storage.

Production startup fails closed when neither complete connection mode is present
or when both are present. Migrations retain the existing boot-time architecture
inside `Fornacast.Application`, with this exact order:

1. validate the legacy-Turso acknowledgement preflight;
2. run `prepare_boot/0`, where `Ecto.Migrator.with_repo/2` starts a temporary Repo,
   migrates, and stops that Repo;
3. start the supervision tree, including the long-lived supervised Repo and all
   application services; and
4. satisfy readiness probes only after those children are ready.

This milestone does not add a container entrypoint or pre-start
`Fornacast.Release.migrate/0` invocation. Internal application ports remain
unpublished; nginx remains the sole public HTTP surface.

Production build tasks must not require a live database or a real credential.
`runtime.exs` therefore uses the existing release-command gate: compile, asset,
`mix release`, and image-build evaluation use a fixed non-connecting keyword
configuration for database `fornacast_build` on loopback. No URL or operator
credential is embedded. An actual release command parses the required URL or
component mode. Contract tests prove that build-time evaluation does not connect
or log connection values and that release startup still fails when runtime
configuration is absent or ambiguous.

The published image no longer includes or advertises a Turso Ecto runtime mode.
The retained `FORNACAST_DATABASE_ADAPTER=turso` source path is compile-only until
the complete schema is again installable; documentation must not instruct users
to run the current application on it.

## Backup and restore

The default Compose backup uses a logical PostgreSQL dump plus one filesystem
volume snapshot. The database must remain running for `pg_dump`, while every
application writer is stopped:

1. stop `app` and `nginx`, leaving `db` healthy;
2. run `pg_dump` inside the `db` container with `docker compose exec -T db`,
   producing a custom-format dump on the host;
3. archive `fornacast-data` while the app remains stopped; this captures bare
   repositories, SSH state, Concord config/VSR data, LocalCAS, and staging;
4. record checksums for the dump and archive; and
5. restart `app` and `nginx` after both artifacts are durable.

The host never needs to resolve the Compose-only hostname `db` or expose port
5432. Restore is explicitly destructive. Before confirmation or any service or
database mutation, it verifies both recorded checksums, runs `pg_restore --list`
against the dump, and lists the filesystem archive to catch truncation or
corruption. It then requires operator confirmation and:

1. stops `app` and `nginx`;
2. uses PostgreSQL 17's `dropdb --force --if-exists` inside the `db` container to
   terminate remaining sessions and remove the target database;
3. recreates the database with `createdb` under the configured PostgreSQL owner;
4. streams the custom-format dump to
   `pg_restore --no-owner --no-privileges --exit-on-error` inside `db`;
5. restores `fornacast-data`; and
6. starts `app` and `nginx`, allowing boot-time migrations to advance an older
   restored schema before readiness.

The database service remains running while the target database is replaced, but
it has no application writers. The documented commands use the same
`POSTGRES_DB`/`POSTGRES_USER` values as Compose and must not print the password.

A PostgreSQL dump without `fornacast-data`, or `fornacast-data` without the
matching PostgreSQL dump, is not a supported recovery set.

## Existing Turso installations

No automatic cross-adapter data migration is added in this milestone. Existing
Turso-backed installations may continue running the release that created their
database. Moving them to a PostgreSQL-first release requires an explicit
operator-managed export/import or a fresh PostgreSQL database.

The upgrade documentation must call this out before an operator replaces the
image. Silent creation of an empty PostgreSQL database beside existing Turso data
is not an acceptable migration strategy.

The PostgreSQL release enforces this boundary before automatic migrations. In a
production release, if the legacy Ecto file exists at
`FORNACAST_LEGACY_TURSO_DATABASE_PATH` (default `/data/fornacast.db`), startup
fails unless `FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true`. The error identifies
the path and required operator action without reading or logging database
content. The check does not run in development, tests, or an explicitly compiled
Turso build.

Acknowledgement means the operator has backed up and deliberately migrated or
abandoned that database; it is not an automatic import. Operators should remove
or archive the legacy file after completing the transition so the override is no
longer needed.

Designing an automated Turso-to-PostgreSQL transfer tool is a separate feature.

## Optional Turso compatibility policy

Keeping source compatibility does not mean claiming current runtime usability.

- Turso is not a production recommendation.
- Turso Ecto support is currently compile-only because a fresh database cannot
  install the full schema.
- Turso is not a GitHub-import acceptance database.
- Turso failures do not block releases unless they affect Concord's separate
  supported configuration boundary.
- `concord#90` remains open as a compatibility issue but is no longer a Fornacast
  release blocker.
- No application migration may omit constraints, weaken evidence validation, or
  silently move invariants out of SQL only for Turso.
- The project may restore a non-gating compatibility workflow after a released
  adapter can install and exercise the complete schema.

Documentation must use "dormant compile-only compatibility" rather than
"optional database" or "supported database" for this path until full migration
and runtime qualification return.

## GitHub-import plan impact

R8D cleanup reconciliation resumes against PostgreSQL without changing the
approved fail-closed effect design:

- PostgreSQL remains authoritative for cleanup intent, leases, exact evidence,
  effect-start/effect-finish state, recovery markers, and audit events.
- Anchored filesystem identity and reader/writer permit ordering remain unchanged.
- R8D's required database suite and R10's persistence/publication suite use an
  isolated PostgreSQL build and database.
- The Turso cleanup suite is removed from required milestone acceptance rather
  than skipped inside tests.
- Metadata and organization plans inherit the PostgreSQL acceptance boundary.

The repository, metadata, and organization implementation plans must be edited so
their command blocks and expected results no longer describe Turso as a required
gate. This is a plan correction, not permission to reduce behavioral coverage.

## Error handling

- Missing, partial, or ambiguous production PostgreSQL connection modes raise
  before the Repo starts.
- Invalid PostgreSQL ports, socket paths, or adapter names fail configuration
  parsing with sanitized messages.
- Unacknowledged legacy Turso Ecto data blocks production startup before
  PostgreSQL migrations.
- Connection errors must not include passwords or credential key material.
- Development commands report PostgreSQL readiness failures rather than falling
  back to a local Turso file.
- A compile/runtime adapter mismatch remains a hard error.
- Optional Turso builds retain their existing typed adapter failures; the
  PostgreSQL path does not catch or translate them.

## Verification strategy

### Configuration contracts

- Default compile selects `Ecto.Adapters.Postgres`.
- Explicit Turso and PostgreSQL builds select their requested adapters.
- Development recognizes devenv Unix-socket variables.
- Production accepts URL mode or complete component mode and rejects missing,
  mixed, or partial modes.
- Production build evaluation uses only the fixed non-connecting build config.
- Production legacy-data preflight requires explicit acknowledgement.
- Dockerfile, Compose, CI, E2E, release workflow, `.env.example`, and README agree
  on PostgreSQL defaults.

### Database behavior

- Fresh PostgreSQL create/migrate and migration rollback where supported.
- Full serial PostgreSQL umbrella tests.
- GitHub-import persistence, conflict, publication, and cleanup recovery suites.
- Read/write/cleanup limiter race coverage and stale-writer rejection.
- API, web, SSH, and Git HTTP behavior on the PostgreSQL build.

### Distribution behavior

- Production warnings-as-errors compile with PostgreSQL.
- PostgreSQL-backed OTP release with boot-time migration before readiness.
- Docker Compose health/readiness and HTTP/API/SSH probes.
- Installed release and GHCR smoke proof using PostgreSQL.
- Backup documentation and release notes contract tests.

### Optional compatibility evidence

During this change, run one explicit Turso compile check to prevent accidental
source-branch deletion. The known full-schema migration failure is recorded as
compile-only incompatibility and does not fail PostgreSQL acceptance.

## Rollout order

1. Commit this architecture decision and update the GitHub-import implementation
   plans.
2. Add failing configuration/distribution contract tests for PostgreSQL defaults.
3. Change compile, runtime, dev/test, Docker, Compose, workflow, and documentation
   defaults together.
4. Prove fresh PostgreSQL migration, full tests, release build, and Compose smoke.
5. Update `concord#90` to record that it is no longer a downstream release
   blocker while retaining the compatibility report.
6. Resume and complete the preserved R8D implementation on PostgreSQL.
7. Continue R10, metadata import, and organization import under the corrected
   database boundary.

## Rejected alternatives

### Remove Turso and Concord completely

Rejected because Concord still owns a distinct supported infrastructure role and
the Ecto adapter path can remain isolated without constraining PostgreSQL work.
Removing either would create a separate migration and storage redesign.

### Keep Turso and PostgreSQL as equal required matrices

Rejected because the current full Turso schema cannot install. Marking a known
failure as required blocks unrelated feature delivery without improving safety.

### Weaken the cleanup constraint for Turso

Rejected because SQL evidence validation is part of the fail-closed cleanup
contract. Adapter-specific omission would make the easiest local setup the least
safe one.

### Publish separate PostgreSQL and Turso images

Rejected because the Turso image would advertise a schema that cannot currently
install. One supported PostgreSQL image keeps the operator contract honest.

## Success criteria

The database-boundary migration is complete when:

1. PostgreSQL is the default in code, local tooling, tests, CI, Docker, E2E, and
   releases.
2. The published image starts only with exactly one complete PostgreSQL
   connection mode and passes boot-time migration plus endpoint/protocol probes.
3. Required PostgreSQL suites cover every behavior previously expected from the
   dual matrix, including GitHub-import cleanup.
4. Turso remains an explicit compile-only source path with no weakened schema or
   misleading runtime claim.
5. Concord's embedded configuration/LocalCAS boundary remains unchanged.
6. Operator documentation clearly covers backup, restore, and the absence of an
   automatic Turso-to-PostgreSQL migration.
7. Existing legacy Turso Ecto data cannot be silently ignored during production
   startup.
8. R8D can proceed without an upstream Turso dependency fix.
