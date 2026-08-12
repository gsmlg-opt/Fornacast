# Fornacast

[![GitHub Release](https://img.shields.io/github/v/release/gsmlg-opt/Fornacast)](https://github.com/gsmlg-opt/Fornacast/releases/latest)
[![GHCR](https://img.shields.io/badge/GHCR-gsmlg--dev%2Ffornacast-2496ED?logo=docker&logoColor=white)](https://github.com/orgs/gsmlg-dev/packages/container/package/fornacast)

Fornacast is a small self-hosted Git forge built with Elixir, Phoenix, Erlang/OTP SSH, Ecto on ExTurso/Turso by default, Concord-backed key/value app config, optional PostgreSQL, and Rust NIFs over gitoxide.

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

Optional: use [`devenv.nix`](./devenv.nix) for pinned BEAM, Rust, and a local Postgres 17 instance (port `55432`).

Setup:

```sh
mix deps.get
mix ecto.setup
mix npm.ci
mix test
```

`mix npm.ci` installs the npm workspace under `apps/*` from `package-lock.json`. Use `mix npm.install` when intentionally updating frontend dependencies.

Useful Mix aliases:

```sh
mix format                  # format Elixir / HEEx / asset sources
mix format --check-formatted
mix assets.build            # duskmoon_bundler + Tailwind
mix assets.deploy           # minify + phx.digest (production/CI)
mix compile --warnings-as-errors
```

Run locally:

```sh
mix fornacast.run
```

On a fresh install this prints a setup URL. Open `http://localhost:4890/setup` to create the first admin account, then log in.

Default local endpoints:

- Web: `http://localhost:4890`
- REST API: `http://localhost:4891/api/v3`
- GraphQL: `http://localhost:4891/api/graphql`
- Discovery: `http://localhost:4891/.well-known/fornacast`
- SSH: `ssh://USER@localhost:2222/USER/REPO.git`

The Ecto adapter is selected at **compile time**. Default is Turso/libSQL file databases. To use PostgreSQL, set `FORNACAST_DATABASE_ADAPTER=postgres` and recompile (see [Configuration](#configuration)).

Alternatively, create the first admin headlessly without the web wizard:

```sh
mix fornacast.admin.create \
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
By default Docker Compose uses a local Turso-compatible Ecto database file at `/data/fornacast.db` and a separate Concord key/value config database at `/data/fornacast_config.db`.
Replace `POSTGRES_PASSWORD` only when using the optional PostgreSQL profile.

### Deploy a prebuilt release image

The published image supports Turso/libSQL only. PostgreSQL requires a source
build with the `FORNACAST_DATABASE_ADAPTER=postgres` build argument.

For deployment, anonymous pulls work only when the package is public.
If the package is private, create a separate read-only PAT with `read:packages`
and authenticate before pulling. Do not use the release publisher's
`GHCR_TOKEN`:

```sh
export GHCR_USERNAME=your-github-username
export GHCR_READ_TOKEN=your-read-only-token
printf '%s' "$GHCR_READ_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
```

Choose the release tag to deploy:

```sh
export FORNACAST_IMAGE=ghcr.io/gsmlg-dev/fornacast:0.1.3
docker compose pull app nginx
```

Version tags are convenient but can move. For a truly immutable pin, replace
the tag with `@sha256:<digest>` using the digest printed on the GitHub release page.

Before deployment, keep public port `4000` blocked in the firewall or security
group while starting the instance:

```sh
docker compose up -d --no-build
```

Complete `/setup` locally or through an SSH tunnel, then open public port
`4000`. Port `2222` is the public SSH endpoint; do not publish the internal
application ports `4890` or `4891` directly.

### Build from source

Build and start the default Turso-backed image from source:

```sh
docker compose up --build -d
```

To build and run a PostgreSQL-backed image instead, set `FORNACAST_DATABASE_ADAPTER=postgres` and `DATABASE_URL`, then start the optional Postgres profile:

```sh
FORNACAST_DATABASE_ADAPTER=postgres \
DATABASE_URL=ecto://fornacast:$POSTGRES_PASSWORD@db/fornacast_prod \
docker compose --profile postgres up --build -d
```

Migrations run automatically on container start. Open `http://localhost:4000/setup` to create the first admin account.
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
- `FORNACAST_DATABASE_ADAPTER`, default `turso`; use `postgres` for PostgreSQL builds
- `FORNACAST_DATABASE_PATH`, default `/data/fornacast.db` in production Turso mode
- `TURSO_DATABASE_URL`, optional remote Turso/libSQL URI for the Ecto database
- `TURSO_AUTH_TOKEN`, optional Turso auth token for the Ecto database
- `FORNACAST_CONFIG_DATABASE_PATH`, default `/data/fornacast_config.db` for the Concord key/value config database
- `FORNACAST_CONFIG_TURSO_DATABASE_URL`, optional remote Turso/libSQL URI for Concord-backed app config
- `FORNACAST_CONFIG_TURSO_AUTH_TOKEN`, optional Turso auth token for Concord-backed app config
- `DATABASE_URL`, required only when built with `FORNACAST_DATABASE_ADAPTER=postgres`
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

Development and test also honor:

- `FORNACAST_DATABASE_PATH`, default `fornacast_dev.db`
- `FORNACAST_TEST_DATABASE_PATH`, default `fornacast_test.db`
- `FORNACAST_CONFIG_DATABASE_PATH`, default `fornacast_config_dev.db`
- `FORNACAST_TEST_CONFIG_DATABASE_PATH`, default `fornacast_config_test.db`
- `FORNACAST_SSH_BIND_IP`
- `FORNACAST_SSH_ENABLED`

The Ecto adapter is selected at compile time. Build or recompile with `FORNACAST_DATABASE_ADAPTER=postgres` to use PostgreSQL; omit it for the default ExTurso/Turso-compatible backend. Concord is used separately for app-level key/value config through `Fornacast.ConfigStore`.

### Initialization

The first visit to a fresh instance serves an unauthenticated setup page that creates the first administrator. Do not expose an un-set-up instance to untrusted networks; complete setup immediately after first boot.

## Storage And Backup

Fornacast stores domain state in the configured Ecto database, app-level key/value config in Concord, and bare Git repositories under `FORNACAST_REPO_STORAGE_ROOT`.

Release-asset bytes use embedded LocalCAS under
`FORNACAST_RELEASE_ASSET_STORAGE_ROOT` (default `/data/release-assets` in the
container). The first release supports one Fornacast BEAM with exclusive use of
one volume. Keep the Erlang node name and this root stable; the release image
uses `fornacast@127.0.0.1` by default. Use stop-before-start upgrades, and do
not run rolling or concurrent writers against the same root. Compose gives the
BEAM a 45-second graceful-stop window, which the release acceptance smoke
exercises. Erlang distribution and EPMD are bound to loopback and are not
published by Compose. No S3 listener or S3 credentials are used.

Treat the Ecto database, ConfigStore database, release-asset Concord directory,
CAS directory, and staging directory as one cold recovery set. Stop Fornacast,
back up or restore every member while it remains stopped, then restart. The
default `/data` volume contains all local members; PostgreSQL must be backed up
in the same stopped maintenance window.

Back up all local members together while Fornacast is stopped:

```sh
cp "$FORNACAST_DATABASE_PATH" fornacast.db
cp "$FORNACAST_CONFIG_DATABASE_PATH" fornacast_config.db
tar -C "$FORNACAST_REPO_STORAGE_ROOT" -czf fornacast-repos.tgz .
tar -C "$FORNACAST_SSH_SYSTEM_DIR" -czf fornacast-ssh.tgz .
tar -C "$FORNACAST_RELEASE_ASSET_STORAGE_ROOT" -czf fornacast-release-assets.tgz .
```

For remote Turso databases, use Turso's backup/export workflow for the database and config store, and back up the repository and SSH directories separately.

For PostgreSQL deployments, use `pg_dump "$DATABASE_URL" > fornacast.sql`.

For default Docker Compose deployments, back up the named data volume:

```sh
docker run --rm -v fornacast_fornacast-data:/data -v "$PWD":/backup debian:bookworm-slim \
  tar -C /data -czf /backup/fornacast-data.tgz .
```

Restore requires the database dump, repository/SSH data, and release-asset data from the same point in time.

## Contributing

- Follow the conventions in [`AGENTS.md`](./AGENTS.md) and the DuskMoon UI rules in [`CLAUDE.md`](./CLAUDE.md).
- Keep changes scoped; run `mix format` and relevant `mix test` paths before opening a PR.
- CI runs format checks, `mix compile --warnings-as-errors`, unit tests (Turso + Postgres), and release smoke/e2e workflows.

## Dogfood Gate

Before tagging a release, Fornacast should host this repository as a normal remote for at least one development cycle:

```sh
git remote add fornacast ssh://alice@HOST:2222/alice/fornacast.git
git push fornacast main
git clone ssh://alice@HOST:2222/alice/fornacast.git fornacast-clone
```

Then verify the web UI can browse the source tree, README, commit list, commit details, branches, tags, raw files, and diffs for the pushed repository.
