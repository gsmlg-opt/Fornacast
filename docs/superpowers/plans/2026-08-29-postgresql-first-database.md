# PostgreSQL-First Database Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development`
> (recommended) or `executing-plans` to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PostgreSQL 17 the supported/default Fornacast domain database across development, tests, Docker, CI, E2E, and releases while retaining Turso as dormant compile-only source compatibility and preserving Concord's separate embedded storage.

**Architecture:** Adapter selection remains compile-time, but every default and published artifact selects PostgreSQL. Production configuration separates a fixed non-connecting build config from two mutually exclusive runtime connection modes, and a pre-migration legacy-file check prevents silent abandonment of old Turso domain data. PostgreSQL acceptance replaces Turso/dual-database gates in the remaining GitHub-import plans without weakening cleanup invariants.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto 3.14, Postgrex 0.22, PostgreSQL 17, Docker Compose, GitHub Actions, ExUnit, Bash

---

**Prerequisite:** Read and preserve
`docs/superpowers/specs/2026-08-29-postgresql-first-database-design.md`.

**Isolation:** Execute this plan in the clean PostgreSQL-first worktree. Do not
edit or reset the preserved dirty R8D worktree. After this plan is green, create a
new R8D continuation worktree from these commits and reapply the preserved R8D
patch using the exact-original-base reconstruction procedure in the handoff
section; do not expect a combined diff hash to survive the base change.

**Command convention:** Start the repository-managed database once:

```bash
devenv shell -- env HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=300 mix deps.get
devenv processes up -d --strict-ports postgres
devenv processes wait --timeout 120
devenv shell -- env PGPORT=55432 \
  psql -v ON_ERROR_STOP=1 -d fornacast_test -c 'select 1'
```

Run PostgreSQL Mix commands with an isolated build:

```bash
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first \
  PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix <task-and-arguments>
```

Keep database suites serial with `--max-cases 1`.

## File and module map

- `config/config.exs`: compile-time adapter selection, fixed production build
  Repo config, development PostgreSQL socket/TCP parsing, sensitive-error policy.
- `config/test.exs`: PostgreSQL test default and Sandbox connection config.
- `config/runtime.exs`: actual release URL/component connection modes and fixed
  build-time config.
- `Fornacast.Repo`: PostgreSQL compile-time fallback.
- `Fornacast.LegacyTursoPreflight`: production-only legacy-file acknowledgement
  before temporary migration Repo startup.
- `Fornacast.Application`: exact preflight -> temporary migration Repo ->
  supervised services ordering.
- `docker-compose.yml` / `Dockerfile` / `.env.example`: one PostgreSQL-first
  published image and default deployment.
- `scripts/compose_backup.sh` / `scripts/compose_restore.sh`: paired logical
  PostgreSQL and `fornacast-data` recovery artifacts.
- GitHub Actions workflows: one required PostgreSQL build/test/release path.
- Existing database/distribution contract tests: static and subprocess proof of
  configuration, secrets, workflows, images, Compose, and recovery ordering.
- GitHub-import plans: PostgreSQL-only remaining milestone commands.

### Task 1: Correct the remaining GitHub-import database gates

**Files:**

- Modify: `docs/superpowers/plans/2026-08-25-github-repository-import.md`
- Modify: `docs/superpowers/plans/2026-08-25-github-metadata-import.md`
- Modify: `docs/superpowers/plans/2026-08-25-github-organization-import.md`

- [ ] **Step 1: Add an explicit acceptance-boundary note to every active plan**

Immediately after each plan's prerequisite/design section, add this exact
boundary, changing only the plan filename in the final sentence:

```markdown
**Database acceptance boundary (2026-08-29):** PostgreSQL 17 is the required
domain database for all remaining implementation and release gates. Use
`FORNACAST_DATABASE_ADAPTER=postgres` with an isolated `MIX_BUILD_PATH` and
`PGPORT=55432` for every database-backed command. Turso Ecto support is dormant
compile-only compatibility: do not run it as milestone acceptance and do not
weaken migrations or tests for it. Historical completed Turso evidence below is
retained only as history; every remaining unchecked gate in this plan is
PostgreSQL-only.
```

- [ ] **Step 2: Rewrite every unchecked repository command gate**

In `2026-08-25-github-repository-import.md`:

- Rename R7 Step 6 to a focused PostgreSQL publication suite and give it the
  isolated PostgreSQL prefix.
- Rename R8C.2 to a PostgreSQL RED suite. Replace R8C.6's both-adapter gate with
  one PostgreSQL GREEN persistence suite while preserving every test path and
  assertion.
- Rename Step 8D.8 to `Run the focused PostgreSQL cleanup and read/write race suites`.
- Prefix both Step 8D.8 commands with the explicit PostgreSQL command convention.
- Delete the duplicate Step 8D.9 adapter-parity command and renumber static
  verification/commit to Steps 8D.9 and 8D.10.
- Replace language requiring Turso parity with exact PostgreSQL migration,
  locking, replay, audit, and state-transition proof.
- Rename R10 Step 3 to `Run all focused PostgreSQL suites serially` and use one
  isolated PostgreSQL command for its full suite.
- Remove R10's duplicate PostgreSQL subset from Step 4; retain formatting and
  warnings-as-errors there.

Use this command prefix in every rewritten block:

```bash
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres \
  PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
```

- [ ] **Step 3: Rewrite final metadata and organization gates**

In `2026-08-25-github-metadata-import.md`, make Task 8 one complete PostgreSQL
suite plus format/compile; remove the Turso suite and duplicate PostgreSQL subset.

In `2026-08-25-github-organization-import.md`, remove the Turso file-database
command and retain one complete PostgreSQL acceptance matrix. Keep browser and
protocol assertions unchanged.

- [ ] **Step 4: Verify no remaining active gate requires Turso**

Run:

```bash
rg -n 'FORNACAST_DATABASE_ADAPTER=turso|FORNACAST_TEST_DATABASE_PATH|Run.*Turso|Turso:|complete focused Turso|same.*on PostgreSQL|Turso/PostgreSQL' \
  docs/superpowers/plans/2026-08-25-github-repository-import.md \
  docs/superpowers/plans/2026-08-25-github-metadata-import.md \
  docs/superpowers/plans/2026-08-25-github-organization-import.md
```

Expected: matches remain only in historical completed-task explanation or the new
compile-only boundary, never in any unchecked R7/R8C/R8D/R10/M8/O9 command,
heading, or expected result. Inspect every match; do not treat a zero-exit regex
alone as proof of checkbox state.

- [ ] **Step 5: Commit the corrected gates**

```bash
git add \
  docs/superpowers/plans/2026-08-25-github-repository-import.md \
  docs/superpowers/plans/2026-08-25-github-metadata-import.md \
  docs/superpowers/plans/2026-08-25-github-organization-import.md
git diff --cached --check
git commit -m "docs(import): make PostgreSQL the acceptance gate"
```

### Task 2: Make PostgreSQL the compile, development, and test default

**Files:**

- Create: `apps/fornacast_api/test/database_config_contract_test.exs`
- Modify: `apps/fornacast_api/test/devenv_process_contract_test.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `apps/fornacast/lib/fornacast/repo.ex`
- Modify: `devenv.nix`

- [ ] **Step 1: Write isolated configuration probes**

Create `FornacastAPI.DatabaseConfigContractTest` with a subprocess helper that
clears ambient database variables before every case:

```elixir
defmodule FornacastAPI.DatabaseConfigContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @config Path.join(@root, "config/config.exs")

  @database_env ~w(
    FORNACAST_DATABASE_ADAPTER DATABASE_URL
    PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE
    POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT POSTGRES_DB
  )

  test "omitted adapter selects PostgreSQL with a non-sensitive dev config" do
    {output, 0} = read_config(:dev, [])
    assert output =~ ~s(adapter="postgres")
    assert output =~ "repo_adapter=Ecto.Adapters.Postgres"
    assert output =~ ~s(database="fornacast_dev")
  end

  test "development prefers PG variables and recognizes Unix sockets" do
    {output, 0} =
      read_config(:dev,
        PGUSER: "socket_user",
        PGPASSWORD: "socket_password",
        PGHOST: "/tmp/fornacast-pg",
        PGPORT: "55432",
        PGDATABASE: "socket_db",
        POSTGRES_HOST: "ignored.example"
      )

    assert output =~ ~s(username="socket_user")
    assert output =~ ~s(database="socket_db")
    assert output =~ ~s(socket_dir="/tmp/fornacast-pg")
    assert output =~ "hostname=nil"
    assert output =~ "port=55432"
    refute output =~ "ignored.example"
  end

  test "development falls back to the local Unix user" do
    {output, 0} = read_config(:dev, USER: "local_fornacast_user")
    assert output =~ ~s(username="local_fornacast_user")
  end

  test "explicit adapter aliases remain compile-selectable" do
    for adapter <- ["postgres", "postgresql"] do
      {output, 0} = read_config(:dev, FORNACAST_DATABASE_ADAPTER: adapter)
      assert output =~ "repo_adapter=Ecto.Adapters.Postgres"
    end

    for adapter <- ["turso", "libsql"] do
      {output, 0} = read_config(:dev, FORNACAST_DATABASE_ADAPTER: adapter)
      assert output =~ "repo_adapter=Ecto.Adapters.Turso"
    end

    {output, status} = read_config(:dev, FORNACAST_DATABASE_ADAPTER: "unsupported")
    assert status != 0
    assert output =~ "unsupported FORNACAST_DATABASE_ADAPTER"
  end

  test "development accepts TCP and rejects an invalid port" do
    {tcp, 0} = read_config(:dev, PGHOST: "127.0.0.1", PGPORT: "5433")
    assert tcp =~ ~s(hostname="127.0.0.1")
    assert tcp =~ "socket_dir=nil"
    assert tcp =~ "port=5433"

    {invalid, status} = read_config(:dev, PGPORT: "5432x")
    assert status != 0
    assert invalid =~ "PGPORT/POSTGRES_PORT must be a decimal integer from 1 through 65535"
  end

  test "development rejects an invalid host without echoing it" do
    invalid_host = "invalid\nhost"
    {output, status} = read_config(:dev, PGHOST: invalid_host)

    assert status != 0
    assert output =~ "PGHOST/POSTGRES_HOST must be a printable nonempty host or socket path"
    refute output =~ invalid_host
  end

  defp read_config(env, overrides) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    script = """
    config = Config.Reader.read!(#{inspect(@config)}, env: #{inspect(env)})
    values = Keyword.fetch!(config, :fornacast)
    repo = Keyword.fetch!(values, Fornacast.Repo)
    IO.puts("adapter=\#{inspect(values[:database_adapter])}")
    IO.puts("repo_adapter=\#{inspect(values[:repo_adapter])}")
    for key <- [:username, :database, :hostname, :socket_dir, :port] do
      IO.puts("\#{key}=\#{inspect(repo[key])}")
    end
    """

    env =
      @database_env
      |> Map.new(&{&1, nil})
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
      |> Map.to_list()

    System.cmd(elixir, ["-e", script], cd: @root, env: env, stderr_to_stdout: true)
  end
end
```

- [ ] **Step 2: Extend the devenv contract test**

Add assertions that `devenv.nix` enables PostgreSQL 17, uses socket-only
`listen_addresses = ""`, port `55432`, and provisions both exact database names:

```elixir
assert source =~ ~s(package = pkgs-stable.postgresql_17)
assert source =~ ~s(port = 55432)
assert source =~ ~s(listen_addresses = "")
assert source =~ ~s({name = "fornacast_dev";})
assert source =~ ~s({name = "fornacast_test";})
```

- [ ] **Step 3: Run the RED configuration tests**

```bash
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first-red \
  PGPORT=55432 \
  mix test \
  apps/fornacast_api/test/database_config_contract_test.exs \
  apps/fornacast_api/test/devenv_process_contract_test.exs \
  --max-cases 1
```

Expected: FAIL because omitted adapter is Turso, dev ignores `PG*`/socket/port,
and devenv does not provision `fornacast_dev`. The outer test process is
explicitly PostgreSQL so the umbrella's setup alias can install migration 00430;
the isolated configuration subprocess still clears the adapter to prove the old
omitted default.

- [ ] **Step 4: Implement one bounded PostgreSQL config parser in `config/config.exs`**

Set the default adapter to `postgres`. For non-production PostgreSQL config, use
this shape before the existing adapter case:

```elixir
parse_postgres_port! = fn raw ->
  case Integer.parse(raw) do
    {port, ""} when port in 1..65_535 -> port
    _ -> raise "PGPORT/POSTGRES_PORT must be a decimal integer from 1 through 65535"
  end
end

postgres_connection = fn default_database ->
  host = System.get_env("PGHOST") || System.get_env("POSTGRES_HOST", "localhost")
  port = System.get_env("PGPORT") || System.get_env("POSTGRES_PORT", "5432")

  unless is_binary(host) and byte_size(host) in 1..4096 and String.valid?(host) and
           String.printable?(host) and not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, host) and
           :binary.match(host, <<0>>) == :nomatch do
    raise "PGHOST/POSTGRES_HOST must be a printable nonempty host or socket path"
  end

  connection =
    if Path.type(host) == :absolute do
      [hostname: nil, socket_dir: host]
    else
      [hostname: host, socket_dir: nil]
    end

  [
    username:
      System.get_env("PGUSER") || System.get_env("POSTGRES_USER") ||
        System.get_env("USER", "postgres"),
    password: System.get_env("PGPASSWORD") || System.get_env("POSTGRES_PASSWORD"),
    database:
      System.get_env("PGDATABASE") || System.get_env("POSTGRES_DB", default_database),
    port: parse_postgres_port!.(port)
  ] ++ connection
end
```

For `config_env() == :prod`, do not call `postgres_connection`. Install this
fixed non-connecting build config immediately so changing the default cannot
embed an ambient production credential between Tasks 2 and 3:

```elixir
[
  hostname: "127.0.0.1",
  socket_dir: nil,
  port: 5432,
  database: "fornacast_build"
]
```

Set `show_sensitive_data_on_connection_error: config_env() != :prod`.

- [ ] **Step 5: Change every compile/test fallback and devenv database list**

Make these exact changes:

```elixir
# config/config.exs and config/test.exs
System.get_env("FORNACAST_DATABASE_ADAPTER", "postgres")

# apps/fornacast/lib/fornacast/repo.ex
@adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Postgres)
```

Add `{name = "fornacast_dev";}` before the existing test database in
`devenv.nix`.

- [ ] **Step 6: Run GREEN config tests and an actual default adapter check**

```bash
devenv shell -- env \
  MIX_BUILD_PATH=_build/postgresql-first \
  PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/fornacast_api/test/database_config_contract_test.exs \
  apps/fornacast_api/test/devenv_process_contract_test.exs \
  --max-cases 1

devenv shell -- env \
  MIX_BUILD_PATH=_build/postgresql-first \
  PGPORT=55432 \
  mix run --no-start -e 'IO.inspect(Fornacast.Repo.__adapter__())'
```

Expected: all tests pass and the probe prints `Ecto.Adapters.Postgres`.

- [ ] **Step 7: Commit compile/dev/test defaults**

```bash
git add \
  apps/fornacast_api/test/database_config_contract_test.exs \
  apps/fornacast_api/test/devenv_process_contract_test.exs \
  apps/fornacast/lib/fornacast/repo.ex \
  config/config.exs config/test.exs devenv.nix
git diff --cached --check
git commit -m "feat(database): default local builds to PostgreSQL"
```

### Task 3: Separate production build config from runtime credentials

**Files:**

- Modify: `apps/fornacast_api/test/database_config_contract_test.exs`
- Modify: `apps/fornacast_api/test/release_distribution_contract_test.exs`
- Modify: `apps/forge_accounts/test/github_credential_vault_test.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Add build-config secret-exclusion tests**

Extend `DatabaseConfigContractTest` with a helper that serializes the complete
config term. For `config/config.exs` at `env: :prod` and `runtime.exs` with
`RELEASE_COMMAND` unset, inject these sentinels:

```elixir
sentinels = [
  "ecto://sentinel:secret@prod.example/sentinel_db",
  "sentinel_user",
  "sentinel_password",
  "prod.example",
  "sentinel_db"
]
```

Assert both reads succeed, contain Repo options
`[hostname: "127.0.0.1", port: 5432, database: "fornacast_build"]`, contain no
`:url`, `:username`, or `:password`, and contain none of the sentinel byte
strings. Read `config/config.exs` and `runtime.exs` as a merged configuration as
well as separately, then apply `Ecto.Repo.Supervisor.parse_url/1` with the same
merge direction Ecto uses. A URL without userinfo must have no effective
`:username` or `:password`; a complete URL must supply every effective
connection field itself. Also assert production config sets
`show_sensitive_data_on_connection_error: false`.

Before reading `runtime.exs`, the subprocess defines a minimal Repo stub with the
adapter module supplied by the test. This exercises the same immutable function
that a built release exposes without depending on an ambient shell value:

```elixir
defmodule Fornacast.Repo do
  def __adapter__, do: Ecto.Adapters.Postgres
end
```

Use the Turso module in the reverse-direction mismatch cases. Production code
must call the real compiled `Fornacast.Repo.__adapter__/0`; do not add a mutable
Application-env marker as a proxy for the compiled adapter.

- [ ] **Step 2: Add the complete runtime mode matrix**

Use isolated subprocesses with `RELEASE_COMMAND=start` and assert:

```elixir
assert_runtime_ok(DATABASE_URL: "ecto://user:pass@db.example/fornacast")

assert_runtime_ok(
  POSTGRES_HOST: "db",
  POSTGRES_DB: "fornacast_prod",
  POSTGRES_USER: "fornacast",
  POSTGRES_PASSWORD: "p@ss:/#?[]",
  POSTGRES_PORT: "5432"
)
```

The component result must retain the password exactly. Add failure cases for:

- neither mode;
- blank URL;
- malformed URL and malformed URL query values containing sentinel userinfo;
- URL plus any component variable that is present, including an empty one;
- each missing or blank required component;
- blank, zero, `65536`, negative, nondecimal, and trailing-garbage ports.

Every failure assertion checks only a fixed classification message and refutes
all supplied sentinel values in output.

Add a compile/runtime mismatch case: seed compiled adapter `postgres`, set
`FORNACAST_DATABASE_ADAPTER=turso`, and require a sanitized failure before
connection parsing. Repeat in the other direction with compiled `turso` and
runtime `postgres`. Also prove `postgresql` is compatible with compiled
`postgres`, and `libsql` with compiled `turso`.

- [ ] **Step 3: Run the RED production-config tests**

```bash
devenv shell -- mix test \
  apps/fornacast_api/test/database_config_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/forge_accounts/test/github_credential_vault_test.exs \
  --max-cases 1
```

Expected: the Task 2 production compile assertions already pass, while the test
command as a whole FAILS because runtime config is URL-only, build/runtime merge
behavior is unproved, adapter mismatch is unchecked, and runtime sensitive-error
policy is not yet explicit.

- [ ] **Step 4: Mirror the fixed build configuration in runtime config**

Task 2 installs the literal in `config/config.exs`. Reuse the same literal in
`runtime.exs` when `RELEASE_COMMAND` is absent or empty, and cover the two copies
with an equality assertion:

```elixir
postgres_build_config = [
  hostname: "127.0.0.1",
  socket_dir: nil,
  port: 5432,
  database: "fornacast_build"
]
```

No build task starts the Repo, and no operator connection variable is read into
the production compile config.

- [ ] **Step 5: Implement exact runtime URL/component parsing**

In `runtime.exs`, preserve raw presence separately from nonempty validity. A URL
variable conflicts with any present component variable, even if that component
is empty. Component mode defaults the port only when `POSTGRES_PORT` is absent;
a present empty port is invalid. Parse a supplied port as `1..65_535`, and return
exactly one of:

```elixir
database_url = System.get_env("DATABASE_URL")

components = %{
  hostname: System.get_env("POSTGRES_HOST"),
  port: System.get_env("POSTGRES_PORT"),
  database: System.get_env("POSTGRES_DB"),
  username: System.get_env("POSTGRES_USER"),
  password: System.get_env("POSTGRES_PASSWORD")
}

url_present? = not is_nil(database_url)
component_present? = Enum.any?(components, fn {_key, value} -> not is_nil(value) end)

case {url_present?, component_present?} do
  {true, false} -> validate_nonempty_url_and_build_url_mode
  {false, true} -> validate_complete_components_and_build_component_mode
  {false, false} -> raise "configure exactly one PostgreSQL connection mode"
  {true, true} -> raise "configure exactly one PostgreSQL connection mode"
end
```

The two named validation branches are local functions/closures, not literal
atoms: URL rejects `""` and pre-validates the complete value with
`Ecto.Repo.Supervisor.parse_url/1` inside `try/rescue`, translating every parser
failure to `DATABASE_URL is invalid` without retaining or printing the original
exception. Component mode rejects empty required values, treats a missing port
as `5432`, and sends a present port through the strict parser.

```elixir
[url: database_url]
```

or:

```elixir
[
  hostname: postgres_host,
  port: postgres_port,
  database: postgres_database,
  username: postgres_user,
  password: postgres_password
]
```

Use only these sanitized errors:

```text
configure exactly one PostgreSQL connection mode
PostgreSQL component mode requires host, database, user, and password
POSTGRES_PORT must be a decimal integer from 1 through 65535
DATABASE_URL is invalid
```

Do not interpolate environment values into an exception. During build
evaluation, use the fixed build config without loading the Repo module. During
an actual release command, derive the compiled adapter only from
`Fornacast.Repo.__adapter__/0`: `Ecto.Adapters.Postgres` canonicalizes to
`postgres`, and `Ecto.Adapters.Turso` to `turso`. Any other module raises the
fixed error `compiled database adapter is unsupported`.

Read `FORNACAST_DATABASE_ADAPTER`, when present, only as a consistency assertion
against that immutable Repo result; canonicalize `postgresql` to `postgres` and
`libsql` to `turso`, then raise
`runtime database adapter does not match compiled adapter` on a mismatch. Branch
on the Repo result, never on an operator-selected runtime value. Retain the
explicit compile-only Turso branch for source-build evaluation.

Set `show_sensitive_data_on_connection_error: false` explicitly in the runtime
Repo config as well as the production compile config.

- [ ] **Step 6: Update existing runtime helpers to use PostgreSQL**

Change release-distribution and credential-vault subprocess helpers so ordinary
runtime-config tests provide one complete component mode. Each helper must first
unset `RELEASE_COMMAND`, `FORNACAST_DATABASE_ADAPTER`, `DATABASE_URL`, and all
five component variables, then add its exact case. Never let an ambient developer
or CI connection mode participate in a test. Each bare-Elixir helper defines the
same minimal PostgreSQL Repo stub before `Config.Reader.read!/2`; release-level
tests use the real compiled Repo.

- [ ] **Step 7: Run GREEN config/security tests**

```bash
devenv shell -- mix test \
  apps/fornacast_api/test/database_config_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/forge_accounts/test/github_credential_vault_test.exs \
  --max-cases 1
```

Expected: all tests pass; no sentinel database credential appears in config
serialization or an error.

- [ ] **Step 8: Commit production config separation**

```bash
git add \
  apps/fornacast_api/test/database_config_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/forge_accounts/test/github_credential_vault_test.exs \
  config/config.exs config/runtime.exs
git diff --cached --check
git commit -m "feat(database): validate PostgreSQL runtime configuration"
```

### Task 4: Block silent abandonment of legacy Turso domain data

**Files:**

- Create: `apps/fornacast/lib/fornacast/legacy_turso_preflight.ex`
- Create: `apps/fornacast/test/legacy_turso_preflight_test.exs`
- Modify: `apps/fornacast/lib/fornacast/application.ex`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write focused preflight tests**

Create cases for:

- disabled preflight with a present file;
- PostgreSQL with no legacy file;
- PostgreSQL with present unacknowledged file;
- PostgreSQL with exact `true` acknowledgement;
- explicit Turso adapter with a present file;
- relative, NUL-containing, non-printable, and over-4096-byte configured paths;
- an error message that contains the escaped path and acknowledgement variable
  but never file contents; and
- `Fornacast.Application.prepare_start/0` failing before storage-root creation.

Use `ExUnit.Case, async: false` because these tests mutate global Application and
System environment. Snapshot every touched value and restore it with `on_exit/1`.
Exercise NUL/non-printable/oversized values through the pure `validate_path/1`
surface below; operating systems do not allow a NUL byte in an environment
variable.

The ordering regression uses `@tag :tmp_dir`, points `repo_storage_root` to an
absent child, creates a legacy file containing `legacy-secret-content`, and
asserts the storage root remains absent after the preflight raises.

- [ ] **Step 2: Run the RED preflight tests**

```bash
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first \
  PGPORT=55432 \
  mix test apps/fornacast/test/legacy_turso_preflight_test.exs --max-cases 1
```

Expected: FAIL because the module and `prepare_start/0` do not exist.

- [ ] **Step 3: Implement `Fornacast.LegacyTursoPreflight`**

Use this public surface:

```elixir
defmodule Fornacast.LegacyTursoPreflight do
  @moduledoc false
  @max_path_bytes 4096

  @spec verify!() :: :ok
  def verify! do
    if enabled?() and postgres?() do
      path = legacy_path!()

      if File.exists?(path) and
           System.get_env("FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA") != "true" do
        raise RuntimeError,
              "legacy Turso database detected at #{inspect(path)}; back it up and set " <>
                "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true only after an intentional transition"
      end
    end

    :ok
  end

  @doc false
  @spec validate_path(term()) :: {:ok, String.t()} | {:error, :invalid_path}
  def validate_path(value)
      when is_binary(value) and byte_size(value) in 1..@max_path_bytes do
    if String.valid?(value) and String.printable?(value) and
         not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value) and
         :binary.match(value, <<0>>) == :nomatch and Path.type(value) == :absolute do
      {:ok, Path.expand(value)}
    else
      {:error, :invalid_path}
    end
  end

  def validate_path(_value), do: {:error, :invalid_path}

  defp enabled?, do: Application.get_env(:fornacast, :legacy_turso_preflight, false)

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp legacy_path! do
    value =
      System.get_env("FORNACAST_LEGACY_TURSO_DATABASE_PATH", "/data/fornacast.db")

    case validate_path(value) do
      {:ok, path} ->
        path

      {:error, :invalid_path} ->
        raise "FORNACAST_LEGACY_TURSO_DATABASE_PATH must be a printable absolute path"
    end
  end
end
```

- [ ] **Step 4: Preserve exact boot ordering**

Add:

```elixir
@doc false
@spec prepare_start() :: :ok
def prepare_start do
  :ok = Fornacast.LegacyTursoPreflight.verify!()
  prepare_boot()
end
```

and replace `:ok = prepare_boot()` in `start/2` with `:ok = prepare_start()`.
Do not change `prepare_boot/0` or `maybe_migrate/0`.

Set `legacy_turso_preflight: false` in base config. In production runtime config,
set it to `require_runtime_env? and database_adapter in ["postgres", "postgresql"]`.

- [ ] **Step 5: Run GREEN preflight and boot suites**

```bash
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first \
  PGPORT=55432 \
  mix test \
  apps/fornacast/test/legacy_turso_preflight_test.exs \
  apps/fornacast/test/fornacast_boot_test.exs \
  --max-cases 1
```

Expected: all tests pass and existing boot-migration/storage behavior remains
unchanged after a successful preflight.

- [ ] **Step 6: Commit the legacy safety gate**

```bash
git add \
  apps/fornacast/lib/fornacast/legacy_turso_preflight.ex \
  apps/fornacast/lib/fornacast/application.ex \
  apps/fornacast/test/legacy_turso_preflight_test.exs \
  config/config.exs config/runtime.exs
git diff --cached --check
git commit -m "feat(database): guard legacy Turso transitions"
```

### Task 5: Make the default Docker deployment PostgreSQL and recovery-safe

**Files:**

- Create: `scripts/compose_backup.sh`
- Create: `scripts/compose_restore.sh`
- Create: `apps/fornacast_api/test/compose_backup_restore_contract_test.exs`
- Modify: `apps/fornacast_api/test/release_distribution_contract_test.exs`
- Modify: `apps/fornacast_api/test/proxy_contract_test.exs`
- Modify: `Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `.env.example`

- [ ] **Step 1: Write Docker/Compose RED contracts**

Assert all of the following:

- Docker build arg and runtime adapter are `postgres`;
- runtime image does not set `FORNACAST_DATABASE_PATH`;
- Compose app passes component mode and no `DATABASE_URL` or primary Turso vars;
- database is a default service with PostgreSQL 17;
- app depends on `db` with `condition: service_healthy`;
- app health checks both internal `/health` endpoints and nginx waits for the app
  health check before exposing the public proxy;
- app and db use the same `POSTGRES_DB`, `POSTGRES_USER`, and
  `POSTGRES_PASSWORD` interpolation;
- Compose requires all three values from `.env` rather than defining a second
  set of database/user defaults in YAML;
- `.env.example` requires blank `SECRET_KEY_BASE` and `POSTGRES_PASSWORD`, defines
  DB/user defaults, and labels config-store Turso variables separately; and
- normalized `docker compose config --services` is exactly `app`, `db`, `nginx`.

- [ ] **Step 2: Write recovery-script RED contracts**

Create a static contract test that runs `bash -n` and verifies strict source order.
For backup:

```text
stop app/nginx < pg_dump < archive /data < SHA256SUMS < restart app/nginx
```

A failed backup after writers stop must leave them stopped and print recovery
guidance; an unconditional EXIT restart is forbidden because it could restart
writers before a complete, durable recovery set exists.

For restore:

```text
sha256sum -c < pg_restore --list < tar -tzf < --confirm-destroy check <
stop app/nginx < dropdb --force < createdb < pg_restore --no-owner <
clear /data < extract /data < start app/nginx
```

Refute `echo "$POSTGRES_PASSWORD"`, `set -x`, hard-coded Compose project volume
names, and any database mutation before integrity/confirmation checks.
Require an exact two-line checksum manifest naming only `fornacast.dump` and
`fornacast-data.tgz`, PostgreSQL 17 container-side `pg_restore --list`, one
Compose-labeled `app` container, and one named `/data` mount.
Require `umask 077`; the fake-command backup run must observe mode `700` on the
backup directory and `600` on the dump, archive, and checksum manifest.

- [ ] **Step 3: Run the RED distribution contracts**

```bash
devenv shell -- mix test \
  apps/fornacast_api/test/compose_backup_restore_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/fornacast_api/test/proxy_contract_test.exs \
  --max-cases 1
```

Expected: FAIL on Turso image/Compose defaults, absent health dependency, and
missing scripts.

- [ ] **Step 4: Implement Dockerfile and Compose defaults**

In `Dockerfile`, change the existing build-stage adapter argument to
`ARG FORNACAST_DATABASE_ADAPTER=postgres`. Add `curl` to the runtime stage's
existing `apt-get install --no-install-recommends` package list for the Compose
health check. In the existing runtime `ENV` block, set
`FORNACAST_DATABASE_ADAPTER=postgres`, retain
`FORNACAST_CONFIG_DATABASE_PATH=/data/fornacast_config.db`, add
`FORNACAST_LEGACY_TURSO_DATABASE_PATH=/data/fornacast.db`, and delete only the
primary Ecto `FORNACAST_DATABASE_PATH` entry.

Compose app/database core:

```yaml
app:
  build:
    args:
      FORNACAST_DATABASE_ADAPTER: postgres
  environment:
    FORNACAST_DATABASE_ADAPTER: postgres
    POSTGRES_HOST: db
    POSTGRES_PORT: 5432
    POSTGRES_DB: ${POSTGRES_DB:?set POSTGRES_DB}
    POSTGRES_USER: ${POSTGRES_USER:?set POSTGRES_USER}
    POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}
  depends_on:
    db:
      condition: service_healthy
  healthcheck:
    test:
      ["CMD-SHELL", "curl -fsS http://127.0.0.1:4890/health >/dev/null && curl -fsS http://127.0.0.1:4891/health >/dev/null"]

db:
  image: postgres:17
  environment:
    POSTGRES_DB: ${POSTGRES_DB:?set POSTGRES_DB}
    POSTGRES_USER: ${POSTGRES_USER:?set POSTGRES_USER}
    POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]

nginx:
  depends_on:
    app:
      condition: service_healthy
```

Remove the `postgres` profile and primary Ecto Turso environment variables.
Retain Concord config-store Turso variables and both named volumes. Put `db`
before `nginx` in the service map so normalized services are deterministically
`app`, `db`, `nginx`. Add `POSTGRES_DB=fornacast_prod` and
`POSTGRES_USER=fornacast` to `.env.example`; Compose itself consumes the three
exact `.env` values without fallback defaults.

- [ ] **Step 5: Implement safe backup and restore scripts**

Implement `scripts/compose_backup.sh` with this complete control flow. The
container-label and mount checks prevent `--volumes-from` from targeting an
unrelated container, and the failure trap deliberately leaves writers stopped:

```bash
#!/bin/sh
set -eu
umask 077

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: scripts/compose_backup.sh BACKUP_DIR" >&2
  exit 64
fi

backup_dir=$1
mkdir -- "$backup_dir"

app_container=$(docker compose ps -aq app)
app_container_count=$(printf '%s\n' "$app_container" | awk 'NF { count += 1 } END { print count + 0 }')
if [ "$app_container_count" -ne 1 ]; then
  echo "expected exactly one Compose app container" >&2
  exit 1
fi

app_service=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$app_container")
app_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$app_container")
data_mount=$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Type }}:{{ .Name }}{{ end }}{{ end }}' "$app_container")

if [ "$app_service" != "app" ] || [ -z "$app_project" ]; then
  echo "refusing an app container without exact Compose labels" >&2
  exit 1
fi

case "$data_mount" in
  volume:?*) ;;
  *)
    echo "refusing an app container without one named volume at /data" >&2
    exit 1
    ;;
esac

writers_stopped=false
backup_complete=false
on_exit() {
  status=$?
  if [ "$writers_stopped" = true ] && [ "$backup_complete" = false ]; then
    docker compose stop nginx app >/dev/null 2>&1 || true
    echo "backup failed; app and nginx remain stopped; inspect the partial backup before restarting" >&2
  fi
  exit "$status"
}
trap on_exit EXIT

writers_stopped=true
docker compose stop nginx app

docker compose exec -T db sh -eu -c \
  'exec pg_dump --username="$POSTGRES_USER" --format=custom --no-owner --no-privileges "$POSTGRES_DB"' \
  >"$backup_dir/fornacast.dump"

docker run --rm --volumes-from "$app_container" alpine:3.22 \
  tar -C /data -czf - . >"$backup_dir/fornacast-data.tgz"

(
  cd "$backup_dir"
  sha256sum fornacast.dump fornacast-data.tgz >SHA256SUMS
)
sync

docker compose start app nginx
writers_stopped=false
backup_complete=true
trap - EXIT
```

Implement `scripts/compose_restore.sh` with the matching destructive flow.
Integrity and archive-structure checks occur before the confirmation token is
accepted, and the `/data` deletion can run only after the exact Compose labels
and named mount have been validated:

```bash
#!/bin/sh
set -eu
umask 077

if [ "$#" -ne 2 ] || [ -z "$1" ]; then
  echo "usage: scripts/compose_restore.sh BACKUP_DIR --confirm-destroy" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
backup_dir=$1
confirmation=$2

for artifact in SHA256SUMS fornacast.dump fornacast-data.tgz; do
  if [ ! -f "$backup_dir/$artifact" ]; then
    echo "backup artifact is missing: $artifact" >&2
    exit 1
  fi
done

manifest_lines=$(wc -l <"$backup_dir/SHA256SUMS" | tr -d ' ')
test "$manifest_lines" = 2
grep -Eq '^[0-9a-f]{64}  fornacast\.dump$' "$backup_dir/SHA256SUMS"
grep -Eq '^[0-9a-f]{64}  fornacast-data\.tgz$' "$backup_dir/SHA256SUMS"
(cd "$backup_dir" && sha256sum -c SHA256SUMS)
docker compose exec -T db sh -eu -c 'exec pg_restore --list >/dev/null' \
  <"$backup_dir/fornacast.dump"
tar -tzf "$backup_dir/fornacast-data.tgz" >/dev/null

if [ "$confirmation" != "--confirm-destroy" ]; then
  echo "restore is destructive; pass --confirm-destroy after reviewing the backup" >&2
  exit 64
fi

app_container=$(docker compose ps -aq app)
app_container_count=$(printf '%s\n' "$app_container" | awk 'NF { count += 1 } END { print count + 0 }')
if [ "$app_container_count" -ne 1 ]; then
  echo "expected exactly one Compose app container" >&2
  exit 1
fi

app_service=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$app_container")
app_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$app_container")
data_mount=$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Type }}:{{ .Name }}{{ end }}{{ end }}' "$app_container")

if [ "$app_service" != "app" ] || [ -z "$app_project" ]; then
  echo "refusing an app container without exact Compose labels" >&2
  exit 1
fi

case "$data_mount" in
  volume:?*) ;;
  *)
    echo "refusing an app container without one named volume at /data" >&2
    exit 1
    ;;
esac

restore_complete=false
on_exit() {
  status=$?
  if [ "$restore_complete" = false ]; then
    docker compose stop nginx app >/dev/null 2>&1 || true
    echo "restore failed; app and nginx remain stopped; repair the recovery set before restarting" >&2
  fi
  exit "$status"
}
trap on_exit EXIT

docker compose stop nginx app
docker compose exec -T db sh -eu -c \
  'exec dropdb --username="$POSTGRES_USER" --force --if-exists "$POSTGRES_DB"'
docker compose exec -T db sh -eu -c \
  'exec createdb --username="$POSTGRES_USER" --owner="$POSTGRES_USER" "$POSTGRES_DB"'
docker compose exec -T db sh -eu -c \
  'exec pg_restore --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-owner --no-privileges --exit-on-error' \
  <"$backup_dir/fornacast.dump"

docker run --rm --volumes-from "$app_container" alpine:3.22 sh -eu -c \
  'test -d /data; find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
docker run --rm --volumes-from "$app_container" alpine:3.22 \
  tar -C /data -xzf - <"$backup_dir/fornacast-data.tgz"

docker compose start app nginx
"$script_dir/api_proxy_smoke.sh" "${FORNACAST_PUBLIC_URL:-http://127.0.0.1:4000}"

restore_complete=true
trap - EXIT
```

Keep the script contract test behavioral rather than whitespace-sensitive: find
the exact mutation commands, compare their byte offsets, and execute the two
scripts against fake `docker`, `sha256sum`, `tar`, and `sync` binaries to prove a
failed integrity check or declined confirmation records no `stop`, `dropdb`,
`createdb`, volume clear, or extraction action.

Mark both files executable and assert their Git modes are `100755`:

```bash
chmod +x scripts/compose_backup.sh scripts/compose_restore.sh
stat -c '%a %n' scripts/compose_backup.sh scripts/compose_restore.sh
```

Expected mode: `755` for both; after staging, `git diff --cached --summary` must
show mode `100755`.

- [ ] **Step 6: Run GREEN contracts and normalized Compose checks**

```bash
bash -n scripts/compose_backup.sh scripts/compose_restore.sh
SECRET_KEY_BASE='compose-contract-secret-key-base-00000000000000000000000000000000' \
POSTGRES_DB='fornacast_prod' \
POSTGRES_USER='fornacast' \
POSTGRES_PASSWORD='compose-contract-password' \
docker compose config --services

devenv shell -- mix test \
  apps/fornacast_api/test/compose_backup_restore_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/fornacast_api/test/proxy_contract_test.exs \
  --max-cases 1
```

Expected: shell syntax passes, services output is `app`, `db`, `nginx`, and all
contracts pass.

- [ ] **Step 7: Commit the default deployment**

```bash
git add \
  .env.example Dockerfile docker-compose.yml \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/fornacast_api/test/proxy_contract_test.exs
git diff --cached --check
git commit -m "build(distribution): default Docker deployment to PostgreSQL"
```

- [ ] **Step 8: Commit the paired recovery tools**

```bash
git add \
  scripts/compose_backup.sh scripts/compose_restore.sh \
  apps/fornacast_api/test/compose_backup_restore_contract_test.exs
git diff --cached --check
git commit -m "feat(ops): add paired PostgreSQL backup and restore"
```

### Task 6: Require PostgreSQL across CI, E2E, and releases

**Files:**

- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/test.yml`
- Modify: `.github/workflows/e2e.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `apps/fornacast_api/test/database_workflow_contract_test.exs`
- Modify: `apps/fornacast_api/test/release_distribution_contract_test.exs`

- [ ] **Step 1: Rewrite workflow contracts RED-first**

Require one PostgreSQL test job, PostgreSQL-qualified caches, PostgreSQL 17 health
services for database-backed jobs, explicit PostgreSQL build args, and no required
Turso matrix entry. Release-note assertions must say the image supports
PostgreSQL 17 and distinguish `postgres-data` from `fornacast-data`.
Set an E2E `run-name` that includes `inputs.version` for `workflow_dispatch` so
the exact published-artifact qualification run can be selected and audited.

E2E contracts require component-mode variables and no
`FORNACAST_DATABASE_PATH`. They must preserve archive startup, boot migration,
web/API health, SSH push, browser assets, graceful stop/recreate, and LocalCAS
persistence.

- [ ] **Step 2: Run the RED workflow contracts**

```bash
devenv shell -- mix test \
  apps/fornacast_api/test/database_workflow_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  --max-cases 1
```

Expected: FAIL because workflows still compile/publish Turso and unit tests still
require the dual matrix.

- [ ] **Step 3: Collapse CI and unit tests to PostgreSQL**

- Set `FORNACAST_DATABASE_ADAPTER: postgres` in CI format/build jobs.
- Qualify CI caches with `postgres`.
- Remove the unit-test adapter matrix and set one explicit PostgreSQL environment.
- Keep the PostgreSQL 17 service, health check, and DB/user/password values.
- Keep `MIX_ENV=test` and existing dependency/native caches.

- [ ] **Step 4: Convert installed-release E2E to PostgreSQL**

Add this runner-accessible PostgreSQL 17 service to the `release-smoke` job and
put the matching component values in job env. Remove file-database creation.
Preserve all existing release archive and protocol probes.

```yaml
services:
  postgres:
    image: postgres:17
    env:
      POSTGRES_DB: fornacast_e2e
      POSTGRES_USER: fornacast
      POSTGRES_PASSWORD: fornacast_e2e_password
    ports:
      - 5432:5432
    options: >-
      --health-cmd "pg_isready -U fornacast -d fornacast_e2e"
      --health-interval 5s
      --health-timeout 5s
      --health-retries 20

env:
  POSTGRES_HOST: 127.0.0.1
  POSTGRES_PORT: "5432"
  POSTGRES_DB: fornacast_e2e
  POSTGRES_USER: fornacast
  POSTGRES_PASSWORD: fornacast_e2e_password
```

For container distribution proof, use a unique Compose project name, export a
generated cookie secret and PostgreSQL password for that one step, and set
`FORNACAST_IMAGE` to the source-built image on pull requests or the requested GHCR
image on `workflow_dispatch`. Grant only `contents: read` and `packages: read`;
authenticate to GHCR with `github.token` only in the dispatch branch. On pull
requests, build and tag the source image before `--no-build`:

```bash
docker build \
  --build-arg FORNACAST_DATABASE_ADAPTER=postgres \
  --tag "fornacast-e2e:${GITHUB_SHA}" \
  .
```

Use one failure-safe Compose step with a validated unique project name:

```bash
compose_project="fornacast-e2e-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
case "$compose_project" in
  fornacast-e2e-[0-9]*-[0-9]*) ;;
  *) exit 64 ;;
esac

export COMPOSE_PROJECT_NAME=$compose_project
export SECRET_KEY_BASE="$(openssl rand -hex 32)"
export POSTGRES_DB=fornacast_compose_e2e
export POSTGRES_USER=fornacast
export POSTGRES_PASSWORD="$(openssl rand -hex 24)"
cleanup() {
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose up -d --no-build --wait --wait-timeout 180
scripts/api_proxy_smoke.sh http://127.0.0.1:4000
docker compose exec -T app /app/bin/release_asset_storage_smoke /app write
docker compose restart app
scripts/api_proxy_smoke.sh http://127.0.0.1:4000
docker compose exec -T app /app/bin/release_asset_storage_smoke /app verify
```

The same Compose block must seed its own admin/key/repository through release
RPC and repeat the existing SSH push against port 2222. Do not count the direct
installed-release SSH proof as the container proof. The EXIT trap always cleans
only this validated project and its volumes.

- [ ] **Step 5: Build and publish PostgreSQL release artifacts**

In `release.yml`:

- set global adapter to `postgres`;
- qualify caches with `postgres`;
- pass Docker build arg `FORNACAST_DATABASE_ADAPTER=postgres` explicitly;
- replace Turso-only deployment notes with PostgreSQL 17 component-mode setup,
  legacy acknowledgement, paired backup/restore, and both volume roles; and
- keep release/tag/GHCR token ordering unchanged.

- [ ] **Step 6: Run GREEN workflow contracts**

```bash
devenv shell -- mix test \
  apps/fornacast_api/test/database_workflow_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  --max-cases 1
```

Expected: all workflow/distribution contracts pass.

- [ ] **Step 7: Commit required PostgreSQL workflows**

```bash
git add \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/e2e.yml \
  .github/workflows/release.yml \
  apps/fornacast_api/test/database_workflow_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs
git diff --cached --check
git commit -m "ci: require PostgreSQL across release workflows"
```

### Task 7: Rewrite operator and contributor documentation

**Files:**

- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `.env.example`
- Modify: `apps/fornacast_api/test/release_distribution_contract_test.exs`

- [ ] **Step 1: Add RED documentation contracts**

Require README and release notes to contain all of these exact concepts:

- `PostgreSQL 17` as the supported domain database;
- `DATABASE_URL` URL mode and complete mutually exclusive component mode;
- Concord's separate embedded Turso/VSR config store;
- dormant compile-only Turso Ecto compatibility;
- `FORNACAST_LEGACY_TURSO_DATABASE_PATH` and
  `FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true`;
- no automatic Turso-to-PostgreSQL migration;
- `scripts/compose_backup.sh` and `scripts/compose_restore.sh`;
- paired PostgreSQL dump plus `fornacast-data`; and
- internal ports 4890/4891 remain unpublished.

Refute the old claims `default is Turso`, `supports Turso/libSQL only`,
`PostgreSQL requires a source build`, and `PostgreSQL, optional`.

- [ ] **Step 2: Run the RED documentation contract**

```bash
devenv shell -- mix test \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  --max-cases 1
```

Expected: FAIL until README/AGENTS and release-note language agree.

- [ ] **Step 3: Rewrite README and AGENTS database guidance**

Document:

- devenv PostgreSQL startup and `mix ecto.setup`;
- default Compose deployment with component credentials;
- URL mode for external providers and mutual exclusivity;
- boot-time migrations and readiness;
- legacy-file preflight and operator acknowledgement;
- exact backup/restore script usage and destructive confirmation;
- no automatic cross-adapter migration;
- separate domain DB versus ConfigStore/LocalCAS storage; and
- compile-only Turso source compatibility without runtime instructions.

Update `AGENTS.md` project overview, quick start, adapter notes, safety constraints,
and verification guidance so future agents do not restore Turso as a default or
release gate.

- [ ] **Step 4: Run GREEN docs/distribution contracts**

```bash
devenv shell -- mix test \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/fornacast_api/test/database_workflow_contract_test.exs \
  --max-cases 1
```

Expected: all tests pass and searches find no supported/default Turso Ecto claim.

- [ ] **Step 5: Commit operator documentation**

```bash
git add README.md AGENTS.md .env.example \
  apps/fornacast_api/test/release_distribution_contract_test.exs
git diff --cached --check
git commit -m "docs(database): document PostgreSQL-first operation"
```

### Task 8: Qualify PostgreSQL distribution and preserve optional source compilation

**Files:**

- Modify only files implicated by failing in-scope verification.

- [ ] **Step 1: Start PostgreSQL and prove a fresh migration**

```bash
devenv processes up -d --strict-ports postgres
devenv processes wait --timeout 120
devenv shell -- env PGPORT=55432 \
  psql -v ON_ERROR_STOP=1 -d fornacast_test -c 'select 1'

devenv shell -- bash -eu -o pipefail <<'BASH'
disposable_suffix=$(openssl rand -hex 12)
disposable_db="fornacast_postgresql_first_${disposable_suffix}"
printf '%s\n' "$disposable_db" \
  | grep -Eq '^fornacast_postgresql_first_[0-9a-f]{24}$'

export FORNACAST_DATABASE_ADAPTER=postgres
export MIX_BUILD_PATH=_build/postgresql-first
export MIX_ENV=test
export PGPORT=55432
export POSTGRES_TEST_DB=$disposable_db

database_count=$(psql -v ON_ERROR_STOP=1 -At -d postgres \
  -c "select count(*) from pg_database where datname = '$disposable_db'")
test "$database_count" = 0

created_by_this_run=false
cleanup() {
  status=$?
  if [ "$created_by_this_run" = true ] &&
     printf '%s\n' "$disposable_db" \
       | grep -Eq '^fornacast_postgresql_first_[0-9a-f]{24}$'; then
    dropdb --if-exists "$disposable_db" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

create_output=$(mix ecto.create 2>&1)
if printf '%s\n' "$create_output" | grep -Fq 'has already been created'; then
  echo "refusing to use a database not created by this qualification run" >&2
  exit 1
fi
printf '%s\n' "$create_output" | grep -Fq 'has been created'
created_by_this_run=true

mix ecto.migrate
psql -v ON_ERROR_STOP=1 -At -d "$disposable_db" \
  -c "select to_regclass('public.github_import_repository_cleanups')" \
  | grep -qx github_import_repository_cleanups
mix ecto.rollback --step 1
mix ecto.migrate
BASH
```

Expected: the managed service is on the exact configured port; a cryptographically
unique, prefix-validated database is proved absent, explicitly reported as
created by this run, and installs every migration; migration 00430 rolls down and
back up; and the trap drops it only while `created_by_this_run=true`.

- [ ] **Step 2: Run configuration, boot, workflow, and recovery contracts**

```bash
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first \
  PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/fornacast/test/legacy_turso_preflight_test.exs \
  apps/fornacast/test/fornacast_boot_test.exs \
  apps/fornacast_api/test/database_config_contract_test.exs \
  apps/fornacast_api/test/database_workflow_contract_test.exs \
  apps/fornacast_api/test/compose_backup_restore_contract_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs \
  apps/fornacast_api/test/proxy_contract_test.exs \
  --max-cases 1
```

Expected: zero failures.

- [ ] **Step 3: Run the complete PostgreSQL umbrella suite serially**

```bash
devenv shell -- env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first \
  PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test --max-cases 1
```

Expected: zero failures. If an out-of-scope pre-existing failure appears, record
the exact command/output and stop without modifying unrelated code.

- [ ] **Step 4: Run production build and asset gates**

```bash
devenv shell -- env \
  MIX_ENV=prod \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first-prod \
  mix deps.get --only prod

devenv shell -- env \
  MIX_ENV=prod \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first-prod \
  mix compile --warnings-as-errors

devenv shell -- env \
  MIX_ENV=prod \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first-prod \
  mix npm.ci

devenv shell -- env \
  MIX_ENV=prod \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first-prod \
  mix npm.verify

devenv shell -- env \
  MIX_ENV=prod \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first-prod \
  mix assets.deploy

devenv shell -- env \
  MIX_ENV=prod \
  FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/postgresql-first-prod \
  mix release fornacast --overwrite
```

Expected: every command exits zero without a live production database or operator
database credentials.

- [ ] **Step 5: Prove a live connection failure redacts credentials**

Start the built release against a deliberately closed local port and capture the
same `prepare_boot/0` rescue path used in production:

```bash
probe_root=$(mktemp -d)
probe_log="$probe_root/release.log"
sentinel_password='postgres-live-secret-sentinel'
cleanup_probe() {
  rm -rf -- "$probe_root"
}
trap cleanup_probe EXIT

set +e
timeout 30 env \
  FORNACAST_DATABASE_ADAPTER=postgres \
  FORNACAST_CONFIG_STORE_ENABLED=false \
  FORNACAST_BASE_URL=http://127.0.0.1:4890 \
  FORNACAST_LEGACY_TURSO_DATABASE_PATH="$probe_root/missing-legacy.db" \
  FORNACAST_REPO_STORAGE_ROOT="$probe_root/repos" \
  FORNACAST_RELEASE_ASSET_STORAGE_ROOT="$probe_root/release-assets" \
  FORNACAST_SSH_HOST=127.0.0.1 \
  FORNACAST_SSH_PORT=2222 \
  FORNACAST_SSH_SYSTEM_DIR="$probe_root/ssh" \
  POSTGRES_HOST=127.0.0.1 \
  POSTGRES_PORT=1 \
  POSTGRES_DB=fornacast_probe \
  POSTGRES_USER=fornacast_probe \
  POSTGRES_PASSWORD="$sentinel_password" \
  SECRET_KEY_BASE='release-probe-secret-key-base-000000000000000000000000000000000' \
  RELEASE_NODE="fornacast_probe_$$@127.0.0.1" \
  _build/postgresql-first-prod/rel/fornacast/bin/fornacast start \
  >"$probe_log" 2>&1
probe_status=$?
set -e

test "$probe_status" -ne 0
grep -Eq 'Boot migration failed|connection refused|econnrefused' "$probe_log"
if grep -Fq "$sentinel_password" "$probe_log"; then
  echo "production connection failure leaked the sentinel password" >&2
  exit 1
fi
cleanup_probe
trap - EXIT
```

Expected: startup fails through the migration/Repo path, the captured output has
a useful failure category, and it contains no password bytes. Keep the temporary
path from `mktemp -d`; never point this probe at `/data` or an operator path.

- [ ] **Step 6: Run disposable default-Compose and paired-recovery smoke**

Use a unique project so cleanup cannot touch operator volumes:

```bash
set -eu -o pipefail

smoke_owner=$(openssl rand -hex 12)
printf '%s\n' "$smoke_owner" | grep -Eq '^[0-9a-f]{24}$'
smoke_tmp=$(mktemp -d)
export COMPOSE_PROJECT_NAME="fornacast-postgresql-first-smoke-${smoke_owner}"
export FORNACAST_IMAGE="fornacast-postgresql-first-smoke:${smoke_owner}"
export SECRET_KEY_BASE="$(openssl rand -hex 32)"
export POSTGRES_DB="fornacast_smoke_${smoke_owner}"
export POSTGRES_USER=fornacast
export POSTGRES_PASSWORD="$(openssl rand -hex 24)"
recovery_marker="postgresql-first-recovery-${smoke_owner}"

printf '%s\n' "$COMPOSE_PROJECT_NAME" \
  | grep -Eq '^fornacast-postgresql-first-smoke-[0-9a-f]{24}$'
test -z "$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")"
test -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")"
test -z "$(docker network ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")"
! docker image inspect "$FORNACAST_IMAGE" >/dev/null 2>&1

cleanup_smoke() {
  status=$?
  trap - EXIT
  if printf '%s\n' "$COMPOSE_PROJECT_NAME" \
       | grep -Eq '^fornacast-postgresql-first-smoke-[0-9a-f]{24}$'; then
      docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  if [ "$(docker image inspect -f '{{ index .Config.Labels "fornacast.smoke.owner" }}' "$FORNACAST_IMAGE" 2>/dev/null || true)" = "$smoke_owner" ]; then
      docker image rm "$FORNACAST_IMAGE" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$smoke_tmp"
  exit "$status"
}
trap cleanup_smoke EXIT

docker build \
  --build-arg FORNACAST_DATABASE_ADAPTER=postgres \
  --label "fornacast.smoke.owner=$smoke_owner" \
  --tag "$FORNACAST_IMAGE" \
  .
test "$(docker image inspect -f '{{ index .Config.Labels "fornacast.smoke.owner" }}' "$FORNACAST_IMAGE")" = "$smoke_owner"

docker compose up --no-build -d --wait --wait-timeout 180
scripts/api_proxy_smoke.sh http://127.0.0.1:4000
docker compose exec -T app /app/bin/release_asset_storage_smoke /app write
docker compose exec -T db sh -eu -c \
  'exec psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "CREATE TABLE postgresql_first_recovery_probe (id text PRIMARY KEY, value text NOT NULL); INSERT INTO postgresql_first_recovery_probe VALUES ('\''state'\'', '\''before'\'');"'
docker compose exec -T app sh -eu -c \
  "printf '%s\n' before >'/data/$recovery_marker'"

scripts/compose_backup.sh "$smoke_tmp/backup"
test "$(stat -c %a "$smoke_tmp/backup")" = 700
for artifact in fornacast.dump fornacast-data.tgz SHA256SUMS; do
  test "$(stat -c %a "$smoke_tmp/backup/$artifact")" = 600
done
scripts/api_proxy_smoke.sh http://127.0.0.1:4000

docker compose exec -T db sh -eu -c \
  'exec psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "UPDATE postgresql_first_recovery_probe SET value = '\''after'\'' WHERE id = '\''state'\''; INSERT INTO postgresql_first_recovery_probe VALUES ('\''post_backup'\'', '\''after'\'');"'
docker compose exec -T app sh -eu -c \
  "printf '%s\n' after >'/data/$recovery_marker'; printf '%s\n' after >'/data/$recovery_marker.post-backup'"

scripts/compose_restore.sh "$smoke_tmp/backup" --confirm-destroy
docker compose exec -T db sh -eu -c \
  'exec psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -At -v ON_ERROR_STOP=1 -c "SELECT value FROM postgresql_first_recovery_probe WHERE id = '\''state'\'';"' \
  | grep -qx before
docker compose exec -T db sh -eu -c \
  'exec psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -At -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM postgresql_first_recovery_probe WHERE id = '\''post_backup'\'';"' \
  | grep -qx 0
docker compose exec -T app sh -eu -c \
  "test \"\$(cat '/data/$recovery_marker')\" = before; test ! -e '/data/$recovery_marker.post-backup'"
docker compose exec -T app /app/bin/release_asset_storage_smoke /app verify

docker compose restart app
scripts/api_proxy_smoke.sh http://127.0.0.1:4000
docker compose exec -T app /app/bin/release_asset_storage_smoke /app verify
```

Expected: database health precedes app readiness; the bounded public API/health
smoke passes before and after restart; a LocalCAS object survives restart; the
paired dump plus volume backup restores that object; and only the validated
pre-backup SQL row and filesystem marker return while both post-backup mutations
disappear; and only the validated disposable project image, volumes, and
`mktemp` directory are removed. Every failure preserves its original exit status.
The
workflow E2E from Task 6 separately proves SSH against this Compose topology.

- [ ] **Step 7: Prove dormant Turso source compilation without runtime claims**

```bash
devenv shell -- env \
  MIX_ENV=prod \
  FORNACAST_DATABASE_ADAPTER=turso \
  MIX_BUILD_PATH=_build/turso-compile-only \
  mix compile --warnings-as-errors
```

Expected: compilation exits zero. Do not run full migrations or describe this as
runtime support.

- [ ] **Step 8: Run final static checks**

```bash
devenv shell -- mix format --check-formatted
bash -n scripts/compose_backup.sh scripts/compose_restore.sh
git diff --check a1ad78c..HEAD
git status --short
```

Expected: format, shell syntax, and the complete branch diff pass; worktree and
index are clean.

- [ ] **Step 9: Close any in-scope verification correction at its owning task**

If Step 8 exposes an in-scope defect, return to the task that owns it, add the
smallest regression, apply the fix, rerun that task and Steps 1–8, then stage
only the exact paths printed by `git status --short` after inspecting each one.
Never use a directory-wide final `git add`; do not create an empty qualification
commit. Stop and report any out-of-scope failure under the repository PRD rules.

- [ ] **Step 10: Obtain installed-release and published-GHCR evidence**

This step requires the separately authorized push/PR and release actions; local
workflow contract tests are not a substitute.

1. On the exact implementation commit, let the pull-request E2E workflow finish
   and require its installed-release plus source-built Compose job to pass. Record
   the PR URL, workflow-run URL, and tested commit SHA. `gh pr checks --watch`
   must exit zero.
2. After an authorized release publishes both the archive and GHCR image, dispatch
   the E2E workflow for that exact version. Task 6's run name makes the run
   auditable:

```bash
: "${RELEASE_VERSION:?set RELEASE_VERSION to the published version without a v prefix}"
dispatch_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run e2e.yml --ref main -f version="$RELEASE_VERSION"

published_run_id=
for attempt in $(seq 1 20); do
  published_run_id=$(gh run list \
    --workflow e2e.yml \
    --event workflow_dispatch \
    --limit 20 \
    --json databaseId,displayTitle,createdAt \
    --jq ".[] | select(.displayTitle == \"E2E ${RELEASE_VERSION}\" and .createdAt >= \"${dispatch_started}\") | .databaseId" \
    | head -n 1)
  [ -n "$published_run_id" ] && break
  sleep 3
done

test -n "$published_run_id"
gh run watch "$published_run_id" --exit-status
gh run view "$published_run_id" --json url,headSha,conclusion
```

Expected: the dispatch downloads and boots the published OTP archive, pulls the
matching GHCR image, and passes PostgreSQL HTTP/API/SSH/restart/LocalCAS probes.
If no release action is authorized or no version has been published, stop with
the rollout explicitly **pending this release-time gate**; do not claim the
PostgreSQL-first distribution is fully qualified.

- [ ] **Step 11: Update the upstream compatibility issue and Agent Note**

After all acceptance gates pass, add a comment to
`gsmlg-dev/concord#90` stating that Fornacast production/release acceptance moved
to PostgreSQL, the Turso defect remains open for dormant compatibility, and no
constraint workaround was shipped.

Create the required Agent Note through `save_note` with
`labels: [["project", "fornacast"]]`, recording commits, PostgreSQL test counts,
release/Compose/recovery proof, compile-only Turso result, and the preserved R8D
continuation procedure. Include no credential values or temporary paths.

## R8D continuation handoff

Do not merge this branch into the dirty `codex/github-import` worktree in place.
After the PostgreSQL-first branch is complete:

1. verify the preserved worktree is still at original R8D base `a01a2d6`, record
   `git diff --binary`, its SHA-256 (currently
   `b74697b04b9b37bc37a50a609e53ba5e128d1c0fa741e3fe0f6808108bac1b37`), and
   SHA-256 hashes for every untracked R8D file;
2. create a temporary `.trees/github-import-r8d-preserve` worktree from that
   exact original base, apply the tracked patch, copy only the four known
   untracked R8D files, and prove the binary-diff and untracked hashes match
   exactly there;
3. create `.trees/github-import-postgres` from the final PostgreSQL-first commit,
   apply the preserved patch with three-way context, and copy the four untracked
   files from the exact reconstruction;
4. explicitly review every conflict and every original R8D path against the
   reconstruction. Do **not** require the combined tracked-diff hash to stay
   equal after changing its base: PostgreSQL commits legitimately touch shared
   config and plan files. Only the original-base reconstruction and untracked
   file bytes have exact-hash equality;
5. run R8D's corrected PostgreSQL RED/GREEN suites, complete R8D, and commit it
   only after those gates pass; and
6. leave both the original dirty worktree and exact reconstruction untouched
   until the PostgreSQL-based replacement is independently committed and
   reviewed.

This procedure makes PostgreSQL the base of continued feature work without
stashing, resetting, or risking the only preserved R8D implementation.
