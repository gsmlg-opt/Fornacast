# AGENTS.md

Guidance for AI coding agents working in the Fornacast repository.

## 1. Project Overview & Intent

Fornacast is a small self-hosted Git forge. First-release scope is intentionally narrow: local users, SSH key auth, bare Git storage, Git-over-SSH (and Git-over-HTTP), repository browsing in the web UI, and a GitHub-compatible REST API surface.

**Architecture**

- Elixir **umbrella** monorepo under `apps/`, released as a single OTP release named `fornacast`.
- Domain contexts (`forge_accounts`, `forge_repos`) own Ecto schemas and business rules.
- Shared infra (`fornacast`) owns `Fornacast.Repo`, migrations, Concord-backed config (`Fornacast.ConfigStore`), storage paths, setup, and audit.
- Presentation is split: Phoenix web (`fornacast_web`) and a separate Bandit REST listener (`fornacast_api`).
- Git I/O: Rust NIF over gitoxide (`git_core`) + Erlang/OTP SSH daemon (`git_transport`).
- Default DB adapter is **ExTurso/Turso (libSQL)**; PostgreSQL is compile-time optional via `FORNACAST_DATABASE_ADAPTER=postgres`.
- App-level key/value config uses **Concord** (separate from the Ecto database).

Out of scope for v0.1: CI, packages, LFS, mirrors, forks. Force-push and branch/tag deletion are rejected by write-side policy.

## 2. Quick Start / Local Environment

**Prerequisites:** Elixir 1.20 + OTP 29, Rust ≥ 1.96, Git, OpenSSH client. Optional: [devenv](./devenv.nix) for pinned BEAM/Postgres tooling.

```sh
# Install Elixir deps and create/migrate DB (default Turso/libSQL file DB)
mix deps.get
mix ecto.setup

# Frontend workspace deps (npm via Mix tasks from duskmoon_npm)
mix npm.ci          # CI / lockfile-faithful install
# or: mix npm.install

# Run the app (web :4890, API :4891, SSH :2222)
mix fornacast.run
# Open http://localhost:4890/setup on a fresh instance

# Tests (creates/migrates test DB quietly)
mix test

# Format check / format
mix format --check-formatted
mix format

# Compile (CI uses warnings-as-errors in prod-like builds)
mix compile --warnings-as-errors

# Assets
mix assets.build      # duskmoon_bundler + Tailwind
mix assets.deploy     # minify + phx.digest
```

**Database adapter notes**

- Adapter is selected at **compile time**. Recompile after changing `FORNACAST_DATABASE_ADAPTER`.
- Default/local: Turso file DBs (`fornacast_dev.db`, `fornacast_config_dev.db`).
- Postgres tests: `FORNACAST_DATABASE_ADAPTER=postgres` (CI matrix uses Postgres 17). devenv Postgres listens on port `55432`.

**Headless first admin**

```sh
mix fornacast.admin.create \
  --username alice \
  --email alice@example.com \
  --password "correct horse battery staple"
```

**Default local endpoints**

| Service | URL |
|--------|-----|
| Web | `http://localhost:4890` |
| REST API | `http://localhost:4891/api/v3` |
| SSH | `ssh://USER@localhost:2222/USER/REPO.git` |

See root `README.md` for Docker Compose, env vars, and backup guidance.

## 3. Repository Structure & Key Directories

```
Fornacast/
├── apps/
│   ├── fornacast/           # Shared infra: Repo, migrations, ConfigStore, Setup, Audit, Storage
│   ├── forge_accounts/      # Users, orgs, passwords, SSH keys, API keys/scopes
│   ├── forge_repos/         # Repositories, collaborators, Fornacast.Access authorization
│   ├── git_core/            # Git read/write API; Rustler NIF in native/fornacast_git_core/
│   ├── git_transport/       # OTP SSH daemon, upload-pack / receive-pack
│   ├── fornacast_web/       # Phoenix HTML UI, Git-over-HTTP, assets/
│   └── fornacast_api/       # GitHub-compatible REST (/api/v3), versioned serializers
├── config/                  # config.exs, runtime.exs, env-specific configs
├── deploy/nginx/            # Compose public reverse proxy (same-origin web + API)
├── docs/superpowers/        # Design specs and implementation plans
├── scripts/                 # Smoke helpers, OpenAPI prune, release helpers
├── mix.exs                  # Umbrella + release + aliases
├── package.json             # npm workspaces: apps/*
├── Dockerfile               # Multi-stage release image
├── docker-compose.yml
├── CLAUDE.md                # DuskMoon UI hard rules (also apply here)
└── README.md                # Human operator docs
```

**Where things live**

| Concern | Location |
|--------|----------|
| Migrations | `apps/fornacast/priv/repo/migrations/` |
| Domain APIs | `ForgeAccounts`, `ForgeRepos` context modules |
| AuthZ | `Fornacast.Access` (+ `ForgeRepos.fetch_authorized_repository/4`) |
| Web templates | `apps/fornacast_web/.../controllers/*_html*.ex` and `*.heex` |
| CSS/JS | `apps/fornacast_web/assets/` (Tailwind 4 + `@duskmoon-dev/core/plugin`) |
| API plugs/serializers | `apps/fornacast_api/lib/fornacast_api/{plugs,serializers,validators,controllers}/` |
| Rust NIF | `apps/git_core/native/fornacast_git_core/` |
| Tests | `apps/*/test/` (ExUnit; API has OpenAPI/contract tests) |

## 4. Agent Guidelines & Code Conventions

### Language / Framework Rules

- Prefer **context-module public APIs** (`ForgeAccounts`, `ForgeRepos`, `GitCore`, `Fornacast.*`) over reaching into schemas or Repo from controllers.
- Keep authorization at the domain boundary (`Fornacast.Access` / `fetch_authorized_repository`). Do not invent ad-hoc permission checks in controllers.
- Domain functions typically return `{:ok, t}` / `{:error, atom | {:validation, _} | ...}` tuples. Map API errors through `FornacastAPI.Error.from_domain/2`.
- Record sensitive mutations with `Fornacast.Audit` / `record_multi` when following existing patterns.
- Web UI: **phoenix_duskmoon** only. Controllers use `use FornacastWeb, :html` / `:controller`, which pulls in `PhoenixDuskmoon.Component` and `ArtComponent`.
- Tailwind plugin must be `@duskmoon-dev/core/plugin`. Themes already imported: `sunshine` / `moonlight`.
- Assets are built with **duskmoon_bundler** (`mix assets.build` / `mix assets.deploy`), not a hand-rolled Vite/webpack setup.
- API clients require non-empty `User-Agent`. Supported `X-GitHub-Api-Version` values: `2022-11-28` (default) and `2026-03-10`. Keep versioned serializers/validators in sync when changing response shapes.
- Git write policy for v0.1: allow create/fast-forward/tag create; **reject force-push and ref deletion**.
- Rust NIF changes belong in `git_core`’s native crate; expose them through `GitCore` / `GitCore.Native`, respecting existing limiters (`BlobLimiter`, `ScanLimiter`).

### File Naming & Formatting

- Elixir: `snake_case` files, `PascalCase` modules matching app namespaces (`FornacastWeb.*`, `FornacastAPI.*`, `ForgeRepos.*`, …).
- HEEx templates colocated under controller HTML modules / `repository_html/`.
- Migrations: timestamped under `apps/fornacast/priv/repo/migrations/`.
- Format with `mix format` (`.formatter.exs` includes LiveView HTMLFormatter + DuskmoonBundler.Formatter for `ex`/`exs`/`heex`/`js`/`ts`).
- Do not add DaisyUI, `core_components.ex`, or alternate CSS component libraries.

### Error Handling & Logging

- Prefer typed domain errors over raising in request paths.
- Controllers: web uses Phoenix error views; API uses `FornacastAPI.Error` + fallback controller patterns already in tree.
- Do not log secrets (passwords, tokens, `SECRET_KEY_BASE`, Turso auth tokens). Keep tokens out of fixtures committed to git.
- Avoid leaking private repository existence: unauthorized private repos should surface as not-found where existing code already does so—preserve that behavior.

## 5. Safety Constraints & Anti-Patterns

**Strictly avoid**

- DaisyUI / `core_components.ex` / non-DuskMoon UI kits.
- Publishing unset-up instances or documenting exposure of internal ports `4890`/`4891` as public production origins (Compose uses nginx `:4000` as the public HTTP surface).
- Force-push or ref-deletion support without an explicit product decision and tests.
- Breaking GitHub API compatibility contracts without updating versioned serializers, validators, and contract tests under `apps/fornacast_api/test/`.
- Switching DB adapter without a full recompile; mixing Turso and Postgres assumptions in the same build.
- Committing local DB files (`*.db*`), `_build/`, `deps/`, `node_modules/`, NIF `target/`, or secrets from `.env`.
- Broad refactors unrelated to the task; keep diffs scoped and minimal.
- Implementing out-of-scope forge features (LFS, packages, CI, mirrors, forks) unless explicitly requested.
- Bypassing `Fornacast.Access` / collaborator-org role checks.

**DuskMoon gaps**

If a needed UI capability is missing from DuskMoon packages, open a GitHub issue with label `internal request` (see `CLAUDE.md`) rather than introducing a parallel component library.

**Change hygiene**

- Match existing module style, return shapes, and test placement.
- Run `mix format` and relevant `mix test` paths for touched apps before considering work done.
- For schema changes: add a migration under `fornacast`, update contexts, and cover with ExUnit.
- Prefer extending existing design docs under `docs/superpowers/` when implementing planned workstreams (API foundation, git-data, auth, UI).

## Related Docs

- Operator / deploy: [`README.md`](./README.md)
- UI library rules: [`CLAUDE.md`](./CLAUDE.md)
- Design specs & plans: [`docs/superpowers/`](./docs/superpowers/)
