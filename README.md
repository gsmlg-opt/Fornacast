# Fornacast

[![GitHub Release](https://img.shields.io/github/v/release/gsmlg-opt/Fornacast)](https://github.com/gsmlg-opt/Fornacast/releases/latest)
[![GHCR](https://img.shields.io/badge/GHCR-gsmlg--dev%2Ffornacast-2496ED?logo=docker&logoColor=white)](https://github.com/orgs/gsmlg-dev/packages/container/package/fornacast)

Fornacast is a small self-hosted Git forge built with Elixir, Phoenix,
Erlang/OTP SSH, Ecto, Concord, and Rust NIFs over gitoxide. PostgreSQL 17 is
the supported/default Fornacast domain database in development, test, Docker
Compose, CI, E2E, and releases. Concord's separate embedded Turso/VSR
configuration store remains supported infrastructure; it is not the Ecto
domain database.

The first release target is intentionally narrow: create users and repositories, authenticate Git over SSH (and HTTP) with user credentials or SSH keys, push/clone/fetch with a normal Git client, browse repositories in the web UI, and support the documented GitHub-compatible REST workflow.

The web UI uses the [DuskMoon](https://github.com/gsmlg-dev/phoenix_duskmoon) component system (`phoenix_duskmoon` + `@duskmoon-dev/*`). Do not introduce DaisyUI or other CSS component libraries.

## Current Release Scope

Implemented first-release paths:

- Local users with password login.
- Organizations and collaborator-aware repository access.
- First-admin bootstrap task and unauthenticated `/setup` wizard.
- SSH public key and classic personal access token (API key) management.
- Public and private repository creation.
- Filesystem-backed bare Git storage.
- Erlang/OTP Git-over-SSH daemon and Git-over-HTTP smart protocol.
- `git ls-remote`, `git clone`, `git fetch`, and basic `git push`.
- Initial branch push, fast-forward branch update, new branch push, tag creation, and force-push rejection.
- Repository overview, README rendering, source tree, file view, raw file, commits, commit detail, diffs, branches, tags, and in-repo search.
- `/health` endpoint and automatic boot migrations.
- A separate GitHub-compatible REST listener (`/api/v3`), started with the web application.
- Read-only GraphQL (`/api/graphql`) and public discovery (`/.well-known/fornacast`) on the API listener.

Out of scope for this release: CI, packages, LFS, mirrors, and forks.

## Architecture

Fornacast is an Elixir **umbrella** released as a single OTP release named `fornacast`:

| App | Role |
|-----|------|
| `fornacast` | Shared infra: Ecto repo/migrations, Concord config store, setup, audit, storage paths |
| `forge_accounts` | Users, organizations, passwords, SSH keys, API keys/scopes |
| `forge_repos` | Repositories, collaborators, authorization (`Fornacast.Access`) |
| `git_core` | Git read/write API via Rustler NIF (gitoxide) |
| `git_transport` | OTP SSH daemon (`upload-pack` / `receive-pack`) |
| `fornacast_web` | Phoenix HTML UI, Git-over-HTTP, DuskMoon assets |
| `fornacast_api` | GitHub-compatible REST (`/api/v3`), GraphQL (`/api/graphql`), discovery (`/.well-known/fornacast`) |

Agent-oriented contributor guidance lives in [`AGENTS.md`](./AGENTS.md). Design specs and delivery plans are under [`docs/superpowers/`](./docs/superpowers/).

## Local Development

Prerequisites:

- Elixir 1.20 with Erlang/OTP 29.
- Rust 1.96 or newer.
- Node.js 18+ (frontend workspace install via Mix npm tasks; CI uses `mix npm.ci`).
- Git and OpenSSH client tools for compatibility tests.

[`devenv.nix`](./devenv.nix) pins the BEAM and Rust toolchains and manages the
standard local PostgreSQL 17 service. PostgreSQL listens only on the configured
Unix socket at port `55432` and provisions both `fornacast_dev` and
`fornacast_test`.

Setup:

```sh
devenv processes up -d --strict-ports postgres
devenv processes wait --timeout 120
devenv shell -- mix deps.get
devenv shell -- mix ecto.setup
devenv shell -- mix npm.ci
devenv shell -- mix test
```

`mix npm.ci` installs the npm workspace under `apps/*` from `package-lock.json`. Use `mix npm.install` when intentionally updating frontend dependencies.
An equivalent locally managed PostgreSQL 17 installation can use the standard
`PG*` variables documented under [Configuration](#configuration).

Useful Mix aliases:

```sh
devenv shell -- mix format                  # format Elixir / HEEx / asset sources
devenv shell -- mix format --check-formatted
devenv shell -- mix assets.build            # duskmoon_bundler + Tailwind
devenv shell -- mix assets.deploy           # minify + phx.digest (production/CI)
devenv shell -- mix compile --warnings-as-errors
```

Run locally:

```sh
devenv shell -- mix fornacast.run
```

Or start the application and managed PostgreSQL service in the background with
devenv. Compile once inside the pinned environment after a fresh checkout or a
BEAM version change, then start and wait until both processes report ready:

```sh
devenv shell -- mix compile
devenv processes up -d --strict-ports
devenv processes wait --timeout 300
```

The Fornacast process becomes ready only after the REST listener's `/health`
endpoint returns success. Stop the detached processes with
`devenv processes down`.

On a fresh install this prints a setup URL. Open `http://localhost:4890/setup` to create the first admin account, then log in.

Default local endpoints:

- Web: `http://localhost:4890`
- REST API: `http://localhost:4891/api/v3`
- GraphQL: `http://localhost:4891/api/graphql`
- Discovery: `http://localhost:4891/.well-known/fornacast`
- SSH: `ssh://USER@localhost:2222/USER/REPO.git`

The Ecto adapter is selected at **compile time**, and the default is PostgreSQL.
Normal development needs no adapter override. If an explicit source-compatibility
build changes the adapter, run `mix clean` and recompile before switching back;
never reuse one adapter's build artifacts with another adapter.

Alternatively, create the first admin headlessly without the web wizard:

```sh
devenv shell -- mix fornacast.admin.create \
  --username alice \
  --email alice@example.com \
  --password "correct horse battery staple"
```

## Docker Compose

Create an environment file:

```sh
cp .env.example .env
mix phx.gen.secret
```

Set `SECRET_KEY_BASE` in `.env` to the generated value.
Set a strong `POSTGRES_PASSWORD`; keep the non-secret `POSTGRES_DB` and
`POSTGRES_USER` defaults or change all three values intentionally. Default
Compose requires `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` from
`.env`, uses PostgreSQL 17 component mode, and does not read `DATABASE_URL` from
that file.

The app waits for the PostgreSQL health check before booting. Its health check
requires both internal health endpoints on `4890` and `4891`; nginx waits for
the app health check before accepting traffic. The public ports are `4000` for
HTTP and `2222` for SSH. Application ports `4890` and `4891` remain unpublished.

### Deploy a prebuilt release image

The published image is compiled for the supported PostgreSQL 17 domain
database. Its runtime adapter must match the compiled PostgreSQL adapter.

For deployment, anonymous pulls work only when the package is public.
If the package is private, create a separate read-only PAT with `read:packages`
and authenticate before pulling. Do not use the release publisher's
`GHCR_TOKEN`:

```sh
export GHCR_USERNAME=your-github-username
export GHCR_READ_TOKEN=your-read-only-token
printf '%s' "$GHCR_READ_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
```

Choose a PostgreSQL-first GitHub release and copy its published image digest.
The placeholder below is intentionally invalid so deployment fails safely until
you replace it with that release's exact digest:

```sh
export FORNACAST_IMAGE='ghcr.io/gsmlg-dev/fornacast@sha256:REPLACE_WITH_POSTGRESQL_FIRST_RELEASE_DIGEST'
docker compose pull app nginx
```

Replace the placeholder with the digest printed on the GitHub release page for
that PostgreSQL-first GitHub release. A version tag from the same release can be
used for convenience, but tags can move. `latest` is mutable and must not be
treated as an immutable deployment pin.

Before deployment, keep public port `4000` blocked in the firewall or security
group while starting the instance:

```sh
docker compose up -d --no-build
```

Complete `/setup` locally or through an SSH tunnel, then open public port
`4000`. Port `2222` is the public SSH endpoint; do not publish the internal
application ports `4890` or `4891` directly.

### Build from source

Build and start the PostgreSQL-backed image from source:

```sh
docker compose up --build -d
```

The PostgreSQL release preflight runs before automatic migrations. Container
readiness succeeds only after migrations, the supervised services, and both
application health endpoints are ready. Open `http://localhost:4000/setup` to
create the first admin account.
Nginx is the Compose deployment's only public HTTP service. It serves the web application and the API from the same origin: use `http://localhost:4000/api/v3` for REST resources, `http://localhost:4000/api/uploads` for release-asset uploads, `http://localhost:4000/api/graphql` for GraphQL, and `http://localhost:4000/.well-known/fornacast` for service discovery. The application container's web listener on port `4890` and API listener on port `4891` remain internal to the Compose network.

Alternatively, create the first admin headlessly in the running container without the web wizard:

```sh
docker compose exec app /app/bin/fornacast eval \
  'ForgeAccounts.create_first_admin(%{username: "alice", email: "alice@example.com", password: "correct horse battery staple"})'
```

Then log in, add an SSH key, and create a repository.

## GitHub-Compatible REST API

API clients must send a non-empty `User-Agent`. Pin either supported contract with `X-GitHub-Api-Version: 2022-11-28` or `X-GitHub-Api-Version: 2026-03-10`; omitting the version selects `2022-11-28`.

Store a classic personal access token outside scripts, then authenticate with either GitHub-compatible syntax:

```sh
export FORNACAST_TOKEN='replace-with-your-token'

curl -H 'User-Agent: fornacast-example/1.0' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H "Authorization: Bearer $FORNACAST_TOKEN" \
  http://localhost:4891/api/v3/user

curl -H 'User-Agent: fornacast-example/1.0' \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  -H "Authorization: token $FORNACAST_TOKEN" \
  http://localhost:4891/api/v3/user
```

Classic scopes are `repo` for private-repository access, `public_repo` for public-repository writes, `read:org` for organization reads, and `write:org` for organization mutations. Scopes do not override domain authorization: the authenticated user must also have the required repository or organization role. Legacy API tokens are accepted only during the documented migration window and remain read-only.

Published upload URLs use `/api/uploads` on the same origin as `/api/v3`. Do not publish the internal port `4891` as a separate production origin.

## GraphQL and service discovery

`GET /.well-known/fornacast` is public (no User-Agent or PAT) and returns canonical `base_url`, `api_v3`, `api_graphql`, and `api_uploads` URLs derived from `FORNACAST_BASE_URL`.

GraphQL is available at `/api/graphql` (POST for queries, GET for introspection). Clients must send a non-empty `User-Agent`. Authentication uses the same PAT schemes as REST; GraphQL does **not** use `X-GitHub-Api-Version`. The v1 schema is read-only (`viewer`, `user`, `organization`, `repository`) and reuses domain authorization and opaque `node_id` values as GraphQL `id`s.

```sh
curl -H 'User-Agent: fornacast-example/1.0' \
  -H "Authorization: Bearer $FORNACAST_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ viewer { login databaseId } }"}' \
  http://localhost:4891/api/graphql
```

The complete first-release compatibility claim is still blocked by the `auto_init` compatibility gate: the Git-data delivery plan must implement real repository initialization and pass the end-to-end acceptance workflow before the API is advertised as GitHub compatible.

## Git Usage

After creating a repository named `demo` for user `alice`:

```sh
git init demo
cd demo
echo "# Demo" > README.md
git add README.md
git commit -m "Initial commit"
git branch -M main
git remote add origin ssh://alice@localhost:2222/alice/demo.git
git push -u origin main
git clone ssh://alice@localhost:2222/alice/demo.git ../demo-clone
```

Git-over-HTTP uses the same owner/repo path on the web listener (local example):

```sh
git remote add origin http://alice@localhost:4890/alice/demo.git
```

Supported write-side policy for v0.1:

- Allow branch creation.
- Allow fast-forward branch updates.
- Allow tag creation.
- Reject force pushes.
- Reject branch and tag deletion.

## Configuration

Production environment variables:

- `SECRET_KEY_BASE`
- `FORNACAST_GITHUB_CREDENTIAL_KEYS`, a JSON object mapping key IDs to base64-encoded 32-byte keys
- `FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID`, the key ID used for new GitHub credential writes
- `FORNACAST_DATABASE_ADAPTER`, which must be omitted or match the compiled PostgreSQL adapter
- `DATABASE_URL` for PostgreSQL URL mode
- `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` for PostgreSQL component mode
- `FORNACAST_LEGACY_TURSO_DATABASE_PATH`, the legacy Ecto file checked by the release preflight
- `FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA`, the explicit legacy transition acknowledgement
- `FORNACAST_CONFIG_DATABASE_PATH`, default `/data/fornacast_config.db` for the Concord key/value config database
- `FORNACAST_CONFIG_TURSO_DATABASE_URL`, optional remote Turso/libSQL URI for Concord-backed app config
- `FORNACAST_CONFIG_TURSO_AUTH_TOKEN`, optional Turso auth token for Concord-backed app config
- `FORNACAST_BASE_URL`
- `FORNACAST_API_BIND_IP`, default `0.0.0.0` in the release image
- `FORNACAST_API_PORT`, default `4891` in the release image
- `FORNACAST_API_TRUSTED_PROXIES`, comma-separated trusted proxy CIDRs
- `FORNACAST_REPO_STORAGE_ROOT`
- `FORNACAST_RELEASE_ASSET_STORAGE_ROOT`, default `/data/release-assets` in the release image
- `FORNACAST_RELEASE_ASSET_MAX_BYTES`, default `2147483648` (2 GiB)
- `FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS`, default `86400`
- `FORNACAST_SSH_HOST`
- `FORNACAST_SSH_PORT`
- `FORNACAST_SSH_SYSTEM_DIR`
- `PORT` for the web HTTP listener, default `4890`
- `POOL_SIZE`, optional, default `10`

### Development database connection

Development honors the standard PostgreSQL variables, preferring each `PG*`
form before its `POSTGRES_*` fallback:

- `PGHOST` / `POSTGRES_HOST` (an absolute `PGHOST` is a Unix socket directory)
- `PGPORT` / `POSTGRES_PORT`
- `PGDATABASE` / `POSTGRES_DB` (default `fornacast_dev`)
- `PGUSER` / `POSTGRES_USER`
- `PGPASSWORD` / `POSTGRES_PASSWORD`

### Test database connection

Tests use the same connection variables but an intentionally separate database
name:

- `PGHOST` / `POSTGRES_HOST` (an absolute `PGHOST` is a Unix socket directory)
- `PGPORT` / `POSTGRES_PORT`
- `PGUSER` / `POSTGRES_USER`
- `PGPASSWORD` / `POSTGRES_PASSWORD`
- `POSTGRES_TEST_DB`, default `fornacast_test`

Tests do not use `PGDATABASE` or `POSTGRES_DB` as the database name. Development
and test additionally honor `FORNACAST_CONFIG_DATABASE_PATH`,
`FORNACAST_TEST_CONFIG_DATABASE_PATH`, `FORNACAST_SSH_BIND_IP`, and
`FORNACAST_SSH_ENABLED` for their separate configuration-store and service
settings.

### PostgreSQL connection modes

Non-Compose releases and external PostgreSQL providers must configure exactly
one PostgreSQL connection mode:

1. **URL mode:** set a nonempty `DATABASE_URL` and leave every `POSTGRES_*`
   connection variable unset.
2. **Component mode:** leave `DATABASE_URL` unset and set nonempty
   `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD`;
   `POSTGRES_PORT` defaults to `5432` when it is unset.

Mixed, partial, and explicitly blank configurations are invalid and fail before
the Repo starts. In component mode the password is passed as the exact component
value, so reserved URI characters need no encoding. Do not reconstruct a URI
from component values. URL mode remains appropriate for hosted providers and
uses their normal URI encoding rules. The runtime adapter must match the
compiled PostgreSQL adapter.

### Legacy Turso transition

`FORNACAST_LEGACY_TURSO_DATABASE_PATH` has default `/data/fornacast.db` in the
release image. The PostgreSQL release preflight checks that path before
automatic migrations. If the file exists, back up the legacy file and the
matching `fornacast-data` contents, then intentionally migrate or abandon its
data, and only set `FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true` after making that
decision. No automatic Turso-to-PostgreSQL migration or import is performed;
the acknowledgement is not an import tool. Remove or archive the legacy file
after the transition so the acknowledgement is no longer needed.

### Dormant Turso Ecto compatibility

The explicit Turso/libSQL Ecto build remains as dormant compile-only source
compatibility. It is not a supported runtime, release, or acceptance database:
the current full schema cannot be installed until the upstream
[`concord#90`](https://github.com/gsmlg-dev/concord/issues/90) compatibility
issue is resolved. Concord's separate embedded Turso/VSR configuration store is
still supported and must not be confused with the Fornacast Ecto domain
database. There are intentionally no operator instructions for running the
current release with the Turso Ecto adapter.

GitHub PAT encryption uses a dedicated AES-256-GCM keyring and never derives a
key from `SECRET_KEY_BASE`. Generate a key with `openssl rand -base64 32`, then
configure it under a stable key ID, for example:

```sh
FORNACAST_GITHUB_CREDENTIAL_KEYS='{"2026-08":"<base64-32-byte-key>"}'
FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID=2026-08
```

Submitted PATs must be nonempty binaries no larger than 4096 bytes.
The credential vault releases plaintext only to an arity-one callback for the
duration of one saved or one-time credential operation; it has no public
plaintext-returning decrypt function.

Saved credentials authenticate their database credential ID, local user ID,
provider, and GitHub numeric user ID. One-time credentials instead authenticate
their import run ID, actor ID, provider, and GitHub numeric user ID. Both forms
also authenticate the envelope purpose and format version.

Missing or malformed keyring configuration disables only credential operations;
the rest of the forge still starts, and credential access fails closed. Local
development is unavailable by default unless the two variables above are set.
Tests use a fixed test-only key.

To rotate keys, first keep both the old and new entries in the key map, then
switch the active key ID so new writes use the new key. A later credential
lifecycle task must re-encrypt existing rows before the old key is removed.

The Ecto adapter is selected at compile time. PostgreSQL is the default and the
only supported release build. Changing an explicit source build's adapter
requires `mix clean` followed by a complete recompile. Concord is used
separately for app-level key/value config through `Fornacast.ConfigStore`.

### Initialization

The first visit to a fresh instance serves an unauthenticated setup page that creates the first administrator. Do not expose an un-set-up instance to untrusted networks; complete setup immediately after first boot.

## Storage And Backup

Fornacast stores authoritative domain state in PostgreSQL. The `postgres-data`
volume stores the PostgreSQL domain database. The separate `fornacast-data`
volume stores Git repositories, SSH material, LocalCAS release assets,
staging data, and Concord's separate embedded Turso/VSR configuration store.

Release-asset bytes use embedded LocalCAS under
`FORNACAST_RELEASE_ASSET_STORAGE_ROOT` (default `/data/release-assets` in the
container). The first release supports one Fornacast BEAM with exclusive use of
one volume. Keep the Erlang node name and this root stable; the release image
uses `fornacast@127.0.0.1` by default. Use stop-before-start upgrades, and do
not run rolling or concurrent writers against the same root. Compose gives the
BEAM a 45-second graceful-stop window, which the release acceptance smoke
exercises. Erlang distribution and EPMD are bound to loopback and are not
published by Compose. No S3 listener or S3 credentials are used.

For the default Compose deployment, always back up PostgreSQL and
`fornacast-data` together in the same maintenance window:

```sh
scripts/compose_backup.sh BACKUP_DIR
```

The backup script takes a recovery lock, stops `app` and `nginx` so there are no
application writers, leaves `db` available for `pg_dump`, and creates exactly
`fornacast.dump`, `fornacast-data.tgz`, and `SHA256SUMS`. It restarts the writers
only after both artifacts are durable. Concurrent backup or restore attempts and
partial failures fail closed; inspect any reported recovery lock or stopped
writers before intervening.

`compose_backup.sh` captures only the paired PostgreSQL domain dump and local
`fornacast-data` volume. It does not capture `.env` or external secrets.
Preserve the following separately in a secure secrets system; never store them
as plaintext in `BACKUP_DIR`:

- `FORNACAST_GITHUB_CREDENTIAL_KEYS` and
  `FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID`, which are required to decrypt
  saved GitHub PATs;
- `SECRET_KEY_BASE`;
- PostgreSQL connection credentials such as `DATABASE_URL` or
  `POSTGRES_PASSWORD`; and
- Concord/Turso connection credentials such as
  `FORNACAST_CONFIG_TURSO_DATABASE_URL` and
  `FORNACAST_CONFIG_TURSO_AUTH_TOKEN`.

When remote Concord/Turso state is configured, take a provider-native backup or
snapshot of that remote Concord/Turso state in the same maintenance window. The
local archive cannot capture provider-hosted data.

Restore is destructive and requires explicit confirmation:

```sh
scripts/compose_restore.sh BACKUP_DIR --confirm-destroy
```

The restore script verifies the checksums, PostgreSQL dump, and filesystem
archive before mutation, then stops the writers, replaces the PostgreSQL
database and `fornacast-data`, restarts the application, and verifies the public
health path. A dump or archive from a different maintenance window is not a
supported recovery set.

## Contributing

- Follow the conventions in [`AGENTS.md`](./AGENTS.md) and the DuskMoon UI rules in [`CLAUDE.md`](./CLAUDE.md).
- Keep changes scoped; run `devenv shell -- mix format --check-formatted` and
  relevant `devenv shell -- mix test ... --max-cases 1` paths before opening a PR.
- CI runs format checks, `mix compile --warnings-as-errors`, PostgreSQL unit tests, and release smoke/E2E workflows.

## Dogfood Gate

Before tagging a release, Fornacast should host this repository as a normal remote for at least one development cycle:

```sh
git remote add fornacast ssh://alice@HOST:2222/alice/fornacast.git
git push fornacast main
git clone ssh://alice@HOST:2222/alice/fornacast.git fornacast-clone
```

Then verify the web UI can browse the source tree, README, commit list, commit details, branches, tags, raw files, and diffs for the pushed repository.
