# Fornacast

Fornacast is a small self-hosted Git forge built with Elixir, Phoenix, Erlang/OTP SSH, Ecto on ExTurso/Turso by default, Concord-backed key/value app config, optional PostgreSQL, and Rust NIFs over gitoxide.

The first release target is intentionally narrow: create users and repositories, authenticate Git over SSH with user SSH keys, push/clone/fetch with a normal Git client, and browse repositories in the web UI.

## Current Release Scope

Implemented first-release paths:

- Local users with password login.
- First-admin bootstrap task.
- SSH public key management.
- Private repository creation.
- Filesystem-backed bare Git storage.
- Erlang/OTP Git-over-SSH daemon.
- `git ls-remote`, `git clone`, `git fetch`, and basic `git push`.
- Initial branch push, fast-forward branch update, new branch push, tag creation, and force-push rejection.
- Repository overview, README rendering, source tree, file view, raw file, commits, commit detail, diffs, branches, and tags.
- `/health` endpoint.

Out of scope for this release: issues, pull requests, CI, packages, LFS, mirrors, forks, smart HTTP Git transport, and Forgejo/Gitea API compatibility.

## Local Development

Prerequisites:

- Elixir 1.20 with Erlang/OTP 29.
- Rust 1.96 or newer.
- Git and OpenSSH client tools for compatibility tests.

Setup:

```sh
mix deps.get
mix ecto.setup
mix test
```

Run locally:

```sh
mix phx.server
```

Default local endpoints:

- Web: `http://localhost:4000`
- SSH: `ssh://USER@localhost:2222/USER/REPO.git`

Create the first admin:

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

Build and start:

```sh
docker compose up --build -d
```

To build and run a PostgreSQL-backed image instead, set `FORNACAST_DATABASE_ADAPTER=postgres` and `DATABASE_URL`, then start the optional Postgres profile:

```sh
FORNACAST_DATABASE_ADAPTER=postgres \
DATABASE_URL=ecto://fornacast:$POSTGRES_PASSWORD@db/fornacast_prod \
docker compose --profile postgres up --build -d
```

Run migrations:

```sh
docker compose exec app /app/bin/fornacast eval "Fornacast.Release.migrate()"
```

Create the first admin in the running container:

```sh
docker compose exec app /app/bin/fornacast eval \
  'ForgeAccounts.create_first_admin(%{username: "alice", email: "alice@example.com", password: "correct horse battery staple"})'
```

Open `http://localhost:4000`, log in, add an SSH key, and create a repository.

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
- `FORNACAST_REPO_STORAGE_ROOT`
- `FORNACAST_SSH_HOST`
- `FORNACAST_SSH_PORT`
- `FORNACAST_SSH_SYSTEM_DIR`
- `PORT` for the HTTP listener, default `4000`
- `POOL_SIZE`, optional, default `10`

Development and test also honor:

- `FORNACAST_DATABASE_PATH`, default `fornacast_dev.db`
- `FORNACAST_TEST_DATABASE_PATH`, default `fornacast_test.db`
- `FORNACAST_CONFIG_DATABASE_PATH`, default `fornacast_config_dev.db`
- `FORNACAST_TEST_CONFIG_DATABASE_PATH`, default `fornacast_config_test.db`
- `FORNACAST_SSH_BIND_IP`
- `FORNACAST_SSH_ENABLED`

The Ecto adapter is selected at compile time. Build or recompile with `FORNACAST_DATABASE_ADAPTER=postgres` to use PostgreSQL; omit it for the default ExTurso/Turso-compatible backend. Concord is used separately for app-level key/value config through `Fornacast.ConfigStore`.

## Storage And Backup

Fornacast stores domain state in the configured Ecto database, app-level key/value config in Concord, and bare Git repositories under `FORNACAST_REPO_STORAGE_ROOT`.

Back up both together:

```sh
cp "$FORNACAST_DATABASE_PATH" fornacast.db
cp "$FORNACAST_CONFIG_DATABASE_PATH" fornacast_config.db
tar -C "$FORNACAST_REPO_STORAGE_ROOT" -czf fornacast-repos.tgz .
tar -C "$FORNACAST_SSH_SYSTEM_DIR" -czf fornacast-ssh.tgz .
```

For remote Turso databases, use Turso's backup/export workflow for the database and config store, and back up the repository and SSH directories separately.

For PostgreSQL deployments, use `pg_dump "$DATABASE_URL" > fornacast.sql`.

For default Docker Compose deployments, back up the named data volume:

```sh
docker run --rm -v fornacast_fornacast-data:/data -v "$PWD":/backup debian:bookworm-slim \
  tar -C /data -czf /backup/fornacast-data.tgz .
```

Restore requires the database dump and the repository/SSH data from the same point in time.

## Dogfood Gate

Before tagging `v0.1`, Fornacast should host this repository as a normal remote for at least one development cycle:

```sh
git remote add fornacast ssh://alice@HOST:2222/alice/fornacast.git
git push fornacast main
git clone ssh://alice@HOST:2222/alice/fornacast.git fornacast-clone
```

Then verify the web UI can browse the source tree, README, commit list, commit details, branches, tags, raw files, and diffs for the pushed repository.
