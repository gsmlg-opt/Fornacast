# Deployment, Upgrade, and Recovery

This guide covers the supported Docker Compose deployment. Fornacast uses
PostgreSQL 17 as its only supported domain database for development, testing,
Compose, CI, and releases. See the [README](../README.md#configuration) for the
complete environment-variable reference and non-deployment configuration.

## Storage boundary

Fornacast has distinct storage roles:

- `postgres-data` contains the authoritative PostgreSQL domain database,
  including accounts, repositories, authorization, imports, releases, and
  audit state.
- `fornacast-data` is mounted at `/data` and contains bare Git repositories,
  SSH state, staging data, LocalCAS release-asset bytes and metadata, and
  Concord's embedded Turso/VSR configuration store.
- A remote Concord/Turso configuration store, when configured, remains outside
  both Compose volumes.

Concord's embedded database and LocalCAS metadata are infrastructure state;
they are not the Ecto domain database. A recoverable instance needs a matching
PostgreSQL dump and `fornacast-data` archive from the same maintenance window.

## First deployment

Create the deployment environment from the repository root:

```sh
cp .env.example .env
mix phx.gen.secret
```

Put the generated value in `SECRET_KEY_BASE`, set a strong
`POSTGRES_PASSWORD`, and review the other values in `.env`. Compose uses
PostgreSQL component mode: it passes `POSTGRES_DB`, `POSTGRES_USER`, and
`POSTGRES_PASSWORD` from `.env`, with host `db` and port `5432`. Do not add
`DATABASE_URL` to the Compose app environment. Set `FORNACAST_BASE_URL` to the
full public URL, including its scheme and any nonstandard port, and set
`FORNACAST_SSH_HOST` to the public SSH hostname only.

Choose a PostgreSQL-first release and replace the intentionally invalid digest
placeholder with the exact digest published for that release. If the GHCR
package is private, follow the [README authentication
steps](../README.md#deploy-a-prebuilt-release-image) with a read-only token.

Before starting any service, block public port `4000` in the firewall or
security group so the setup page is not exposed to untrusted traffic. Then
pull and start the complete deployment:

```sh
export FORNACAST_IMAGE='ghcr.io/gsmlg-dev/fornacast@sha256:REPLACE_WITH_POSTGRESQL_FIRST_RELEASE_DIGEST'
docker compose pull app db nginx
docker compose up -d --no-build
```

The database health check gates application startup. The application then runs
the legacy-data preflight and automatic PostgreSQL migrations before starting
its supervised services. Readiness succeeds only after both internal health
endpoints are ready; nginx waits for that readiness check.

Complete `/setup` from the local host or through an SSH tunnel before opening
public port `4000`. Publish only nginx on `4000` and SSH on `2222`; ports `4890`
and `4891` are internal.

## Upgrades

Use stop-before-start upgrades. Only one Fornacast node may mount
`fornacast-data`, and rolling or concurrent writers are unsupported.

Before replacing an image:

1. Read the release notes and confirm the image was built for PostgreSQL.
2. Create the paired backup described below and save deployment secrets
   separately.
3. Pin the new image by its exact digest in `FORNACAST_IMAGE`.
4. Pull and recreate the Compose services. Boot-time migrations complete before
   the new application becomes ready.
5. Check the public health path and normal Git access.

PostgreSQL 17 is the supported server major. Do not point a newer PostgreSQL
major at the existing `postgres-data` volume. A server-major change requires a
separately planned, tested PostgreSQL upgrade or logical dump/restore procedure
and a rollback-ready paired filesystem backup.

### Existing Turso Ecto installations

There is no automatic Turso-to-PostgreSQL domain-data migration. If the legacy
Ecto file exists at `FORNACAST_LEGACY_TURSO_DATABASE_PATH` (default
`/data/fornacast.db`), the PostgreSQL release stops before migrations.

Back up the legacy database and matching filesystem state, then deliberately
migrate the data through an operator-managed process or abandon it. Set
`FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true` only after making that decision;
the acknowledgement does not import data. Archive or remove the legacy file
afterward so the override is no longer required. The retained Turso Ecto path
is dormant compile-only compatibility, not a supported runtime database.

## Backup

Choose a new backup directory path. The backup causes downtime while `app` and
`nginx` are stopped, but leaves `db` running for `pg_dump`:

```sh
scripts/compose_backup.sh BACKUP_DIR
```

The script takes a recovery lock and creates exactly:

- `fornacast.dump`, a custom-format PostgreSQL dump;
- `fornacast-data.tgz`, the matching `/data` volume archive; and
- `SHA256SUMS`, covering both artifacts.

It restarts `app` and `nginx` only after both artifacts are durable. If backup
fails after stopping writers, they remain stopped; inspect the partial backup
and any reported recovery-lock cleanup failure before restarting services.

The backup does not include `.env` or external secrets. Store
`SECRET_KEY_BASE`, PostgreSQL credentials, GitHub credential keyring values,
and Concord/Turso credentials separately in a secrets system. If Concord uses
a remote Turso store, take a provider-native backup or snapshot during the same
maintenance window; the local archive cannot contain that remote state.

## Restore

Restore replaces the target PostgreSQL database and all contents of
`fornacast-data`. Use the complete, matching artifact set and explicit
confirmation:

```sh
scripts/compose_restore.sh BACKUP_DIR --confirm-destroy
```

Before mutation, the script stages regular non-symlink artifacts, verifies the
two-entry checksum manifest, checks the PostgreSQL dump with `pg_restore`, and
lists the filesystem archive. It then stops `app` and `nginx`, recreates the
configured database, restores both data stores, starts the writers, and runs
the public API proxy smoke check. Older restored schemas advance through the
normal boot-time migrations.

If restore fails after writers stop, they remain stopped. Repair or replace the
recovery set and inspect any reported recovery lock before manually restarting
services. Never combine a dump and archive from different maintenance windows.

## External PostgreSQL

A non-Compose release must use exactly one PostgreSQL connection mode:

- URL mode sets a nonempty `DATABASE_URL` and leaves all PostgreSQL component
  variables unset.
- Component mode leaves `DATABASE_URL` unset and sets nonempty
  `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD`;
  `POSTGRES_PORT` defaults to `5432`.

Mixed, partial, or blank modes fail before the Repo starts. Hosted providers
normally use URL mode and their normal URI encoding rules. Component-mode
passwords are passed as exact values. These non-Compose deployments need their
own PostgreSQL backup, filesystem snapshot, readiness, and public-proxy
procedures with the same paired-state and single-writer guarantees.
