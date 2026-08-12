# Release Assets LocalCAS Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land only the process-embedded ExStorageService 0.6.4 LocalCAS foundation needed by future release assets: portable renewable operation leases, exact dependency/configuration, fail-fast storage-root validation, supervised readiness/restart, and an opaque streaming byte-store adapter with path-free capacity reporting that survives production-release and container restarts.

**Architecture:** `forge_releases` owns one explicitly supervised, listener-free ESS instance and keeps ESS values, file descriptors, paths, and raw errors behind `ForgeReleases.AssetStorage`. Initial configuration/root faults fail application boot; runtime ESS loss changes the manager to not-ready and retries the temporary child with bounded exponential backoff. All LocalCAS operations pass adapter-owned loose-blob options and gate once on manager readiness. This plan deliberately stops before release tables, release-domain workflows, HTTP/API endpoints, recovery, or garbage collection.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto with Turso and PostgreSQL adapters, Concord 3 singleton VSR plus `Concord.Turso`, exact Hex `ex_storage_service` 0.6.4, ExUnit, Mix releases, Docker Compose.

---

## Scope boundary

This plan implements the approved foundation in `docs/superpowers/specs/2026-08-12-release-assets-localcas-design.md`. It does not implement release records, asset records, blob inventory, recovery journals, GC jobs, controllers, serializers, routes, S3, Git LFS, or an object-service listener.

Pinned upstream references: [ExStorageService
v0.6.4](https://github.com/gsmlg-opt/ex_storage_service/releases/tag/v0.6.4)
and [PR #16](https://github.com/gsmlg-opt/ex_storage_service/pull/16), which
close recovery #13, direct-options #14, and durable-delete #15.

The repository issues/pulls work is a hard prerequisite. At plan revision time
it was committed on `codex/repository-issues-pulls` but had not landed on
`main`; the implementation branch must contain that committed history before
Task 1 begins. Do not copy files from another worktree or bypass this gate.

## Exact file map

Create:

- `apps/forge_releases/mix.exs`
- `apps/forge_releases/lib/forge_releases/application.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage/config.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage/source.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage/file_system.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage/manager.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage/staged_ref.ex`
- `apps/forge_releases/lib/forge_releases/asset_storage/supervisor.ex`
- `apps/forge_releases/test/test_helper.exs`
- `apps/forge_releases/test/forge_releases/application_test.exs`
- `apps/forge_releases/test/forge_releases/asset_storage/config_test.exs`
- `apps/forge_releases/test/forge_releases/asset_storage/local_cas_contract_test.exs`
- `apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs`
- `apps/forge_releases/test/forge_releases/asset_storage/manager_test.exs`
- `scripts/release_asset_storage_smoke.sh`

Modify after the prerequisite lands:

- `apps/fornacast/lib/fornacast/operation_lease.ex`
- `apps/fornacast/test/operation_lease_test.exs`

Modify for the foundation:

- `mix.exs`
- `mix.lock`
- `apps/fornacast/lib/fornacast/config.ex`
- `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`
- `apps/fornacast_web/test/fornacast_run_task_test.exs`
- `config/config.exs`
- `config/runtime.exs`
- `config/test.exs`
- `.env.example`
- `Dockerfile`
- `docker-compose.yml`
- `README.md`
- `.github/workflows/e2e.yml`
- `apps/fornacast_api/test/release_distribution_contract_test.exs`

### Task 0: Enforce the repository-work prerequisite

- [ ] Run the prerequisite gate from the dedicated worktree:

```bash
test -f apps/forge_issues/mix.exs && \
  test -f apps/forge_pulls/mix.exs && \
  test -f apps/fornacast/lib/fornacast/operation_lease.ex && \
  test -f apps/fornacast/test/operation_lease_test.exs && \
  rg -n 'def (claim|release|update_owned)' \
    apps/fornacast/lib/fornacast/operation_lease.ex
```

Expected before the prerequisite is merged: exit status `1`. Stop this plan at
that result. Update this worktree from the approved repository issues/pulls
branch containing all four files, resolve only genuine merge conflicts, and
rerun the same command.

Expected after the prerequisite is merged: exit status `0` and matches for `claim/5`, `release/2`, and releasing `update_owned/3`.

- [ ] Confirm the prerequisite baseline passes before extending it:

```bash
mix test apps/fornacast/test/operation_lease_test.exs
```

Expected: `0 failures`. Do not create a prerequisite-only commit in this plan.

### Task 1: Add renewable owner-retaining lease operations

**Files:**

- Modify: `apps/fornacast/lib/fornacast/operation_lease.ex`
- Modify: `apps/fornacast/test/operation_lease_test.exs`

- [ ] Add deterministic tests for the exact new APIs. Use required `now:` and `lease_seconds:` keyword keys, UTC second precision, positive seconds, and returned-row threading:

```elixir
test "renew_owned retains ownership and advances expiry and version", %{
  operation: operation,
  now: now
} do
  assert {:ok, claimed} =
           OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 30)

  renewal_now = DateTime.add(now, 10, :second)

  assert {:ok, renewed} =
           OperationLease.renew_owned(GitWriteOperation, claimed,
             now: renewal_now,
             lease_seconds: 45
           )

  assert renewed.lease_owner == "owner-a"
  assert renewed.lease_expires_at == DateTime.add(renewal_now, 45, :second)
  assert renewed.lock_version == claimed.lock_version + 1
end

test "update_owned/4 changes state while retaining a renewed lease", %{
  operation: operation,
  now: now
} do
  assert {:ok, claimed} =
           OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 30)

  update_now = DateTime.add(now, 5, :second)

  assert {:ok, updated} =
           OperationLease.update_owned(
             GitWriteOperation,
             claimed,
             [state: :object_written],
             now: update_now,
             lease_seconds: 40
           )

  assert updated.state == :object_written
  assert updated.lease_owner == "owner-a"
  assert updated.lease_expires_at == DateTime.add(update_now, 40, :second)
  assert updated.lock_version == claimed.lock_version + 1
end

test "owner-retaining operations reject expired, stale, foreign, and invalid handles", %{
  operation: operation,
  now: now
} do
  assert {:ok, claimed} =
           OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 5)

  assert {:error, :lost_lease} =
           OperationLease.renew_owned(GitWriteOperation, claimed,
             now: DateTime.add(now, 6, :second),
             lease_seconds: 30
           )

  assert {:error, :invalid_argument} =
           OperationLease.renew_owned(GitWriteOperation, claimed,
             now: %DateTime{
               now
               | time_zone: "Europe/Paris",
                 zone_abbr: "CET",
                 utc_offset: 3_600
             },
             lease_seconds: 30
           )

  assert {:error, :invalid_argument} =
           OperationLease.renew_owned(GitWriteOperation, claimed,
             now: now,
             lease_seconds: 0
           )

  assert {:error, :invalid_argument} =
           OperationLease.renew_owned(GitWriteOperation, claimed, lease_seconds: 30)

  foreign = %{claimed | lease_owner: "owner-b"}

  assert {:error, :lost_lease} =
           OperationLease.update_owned(
             GitWriteOperation,
             foreign,
             [state: :object_written],
             now: now,
             lease_seconds: 30
           )
end

test "renew_owned never returns a capability superseded after its compare-and-swap", %{
  operation: operation,
  now: now
} do
  assert {:ok, claimed} =
           OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 30)

  result =
    OperationLease.with_test_after_write_hook(
      fn :renew_owned, GitWriteOperation, id, _version ->
        Repo.update_all(from(item in GitWriteOperation, where: item.id == ^id),
          set: [lease_expires_at: DateTime.add(now, -1, :second)]
        )

        Process.put(
          :replacement_claim,
          OperationLease.claim(GitWriteOperation, id, "owner-b", now, 30)
        )
      end,
      fn ->
        OperationLease.renew_owned(GitWriteOperation, claimed,
          now: now,
          lease_seconds: 30
        )
      end
    )

  assert {:error, :lost_lease} = result
  assert {:ok, replacement} = Process.delete(:replacement_claim)
  assert replacement.lease_owner == "owner-b"
end
```

- [ ] Run the focused test and confirm the missing functions are the only new failures:

```bash
mix test apps/fornacast/test/operation_lease_test.exs
```

Expected red result: compile failures reporting undefined `renew_owned/3` and `update_owned/4`.

- [ ] Add the owner-retaining operations and their guarded conditional update to `Fornacast.OperationLease`. Preserve releasing `update_owned/3` unchanged:

```elixir
@spec renew_owned(module(), struct(), keyword()) ::
        {:ok, struct()} | {:error, :lost_lease | :invalid_argument}
def renew_owned(module, operation, options)
    when is_atom(module) and is_list(options) do
  with {:ok, now, expires_at} <- lease_window(options),
       {:ok, renewed} <- renew_owned_row(module, operation, [], now, expires_at, :renew_owned) do
    {:ok, renewed}
  end
end

def renew_owned(_module, _operation, _options), do: {:error, :invalid_argument}

@spec update_owned(module(), struct(), keyword(), keyword()) ::
        {:ok, struct()} | {:error, :lost_lease | :invalid_update | :invalid_argument}
def update_owned(module, operation, updates, options)
    when is_atom(module) and is_list(updates) and is_list(options) do
  with {:ok, now, expires_at} <- lease_window(options),
       {:ok, validated} <- owned_updates(module, operation, updates),
       {:ok, updated} <-
         renew_owned_row(module, operation, validated, now, expires_at, :update_owned_retained) do
    {:ok, updated}
  end
end

def update_owned(_module, _operation, _updates, _options),
  do: {:error, :invalid_argument}

defp owned_updates(module, operation, updates) do
  case validated_updates(module, operation, updates) do
    {:ok, validated} -> {:ok, validated}
    :error -> {:error, :invalid_update}
  end
end

defp lease_window(options) do
  with true <- Keyword.keyword?(options),
       {:ok, now} <- Keyword.fetch(options, :now),
       {:ok, lease_seconds} <- Keyword.fetch(options, :lease_seconds),
       true <- Keyword.keys(options) |> Enum.sort() == [:lease_seconds, :now],
       %DateTime{} <- now,
       :ok <- validate_utc(now),
       true <- is_integer(lease_seconds) and lease_seconds > 0 do
    now = DateTime.truncate(now, :second)
    {:ok, now, DateTime.add(now, lease_seconds, :second)}
  else
    _ -> {:error, :invalid_argument}
  end
end

defp renew_owned_row(
       module,
       %{id: id, lease_owner: owner, lock_version: version},
       updates,
       now,
       expires_at,
       hook_kind
     )
     when is_integer(id) and is_binary(owner) and owner != "" and is_integer(version) do
  query =
    from item in module,
      where:
        item.id == ^id and item.lease_owner == ^owner and item.lock_version == ^version and
          item.lease_expires_at > ^now

  case Repo.update_all(query,
         set: updates ++ [lease_expires_at: expires_at],
         inc: [lock_version: 1]
       ) do
    {1, _} ->
      expected_version = version + 1
      run_after_write_hook(hook_kind, module, id, expected_version)

      case owned_row(module, id, owner, expected_version) do
        nil -> {:error, :lost_lease}
        row -> {:ok, row}
      end

    {0, _} ->
      {:error, :lost_lease}
  end
end

defp renew_owned_row(_module, _operation, _updates, _now, _expires_at, _hook_kind),
  do: {:error, :lost_lease}
```

- [ ] Extend the test-hook case to cover `:update_owned_retained` using the same reclaim-after-write pattern, then rerun the Turso suite:

```bash
mix format apps/fornacast/lib/fornacast/operation_lease.ex \
  apps/fornacast/test/operation_lease_test.exs
mix test apps/fornacast/test/operation_lease_test.exs
```

Expected green result: `0 failures` and both owner-retaining operations return only a currently owned row.

- [ ] Run the same focused lease suite with PostgreSQL:

```bash
FORNACAST_DATABASE_ADAPTER=postgres mix test \
  apps/fornacast/test/operation_lease_test.exs
```

Expected green result: `0 failures`. If the configured PostgreSQL service is unavailable, record that environmental block and do not claim PostgreSQL verification.

- [ ] Commit only the lease extension:

```bash
git add apps/fornacast/lib/fornacast/operation_lease.ex \
  apps/fornacast/test/operation_lease_test.exs
git commit -m "feat(operations): retain ownership across lease updates"
```

### Task 2: Scaffold `forge_releases` and pin ESS 0.6.4

**Files:**

- Create: `apps/forge_releases/mix.exs`
- Create: `apps/forge_releases/lib/forge_releases/application.ex`
- Create: `apps/forge_releases/test/test_helper.exs`
- Create: `apps/forge_releases/test/forge_releases/application_test.exs`
- Modify: `mix.exs`
- Modify: `mix.lock`
- Modify: `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`
- Modify: `apps/fornacast_web/test/fornacast_run_task_test.exs`

- [ ] Create the app project and a red wiring test:

```elixir
# apps/forge_releases/mix.exs
defmodule ForgeReleases.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_releases,
      version: "0.1.3",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ForgeReleases.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:ex_storage_service, "== 0.6.4"}
    ]
  end
end
```

```elixir
# apps/forge_releases/test/test_helper.exs
ExUnit.start()
```

```elixir
# apps/forge_releases/test/forge_releases/application_test.exs
defmodule ForgeReleases.ApplicationTest do
  use ExUnit.Case, async: true

  test "release and development startup include forge_releases in dependency order" do
    release_apps =
      FornacastUmbrella.MixProject.releases()
      |> Keyword.fetch!(:fornacast)
      |> Keyword.fetch!(:applications)
      |> Keyword.keys()

    assert release_apps == [
             :fornacast,
             :forge_accounts,
             :forge_repos,
             :forge_issues,
             :forge_pulls,
             :forge_releases,
             :git_core,
             :git_transport,
             :fornacast_web,
             :fornacast_api
           ]

    assert Mix.Tasks.Fornacast.Run.service_applications() == [
             :fornacast,
             :forge_accounts,
             :forge_repos,
             :git_core,
             :git_transport,
             :forge_issues,
             :forge_pulls,
             :forge_releases,
             :fornacast_api,
             :fornacast_web
           ]
  end
end
```

- [ ] Fetch the exact dependency and confirm the wiring test is red before changing startup lists:

```bash
mix deps.get
mix test apps/forge_releases/test/forge_releases/application_test.exs
```

Expected red result: the release and development application lists omit `:forge_releases`.

- [ ] Add `forge_releases: :permanent` immediately after `forge_pulls` in `mix.exs`; add `:forge_releases` immediately after `:forge_pulls` and before API/web startup in `Mix.Tasks.Fornacast.Run`; and update the existing run-task test to expect that list. Create the minimal application callback:

```elixir
# apps/forge_releases/lib/forge_releases/application.ex
defmodule ForgeReleases.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: ForgeReleases.Supervisor)
  end
end
```

- [ ] Prove the lock resolves only core ESS 0.6.4 and no S3 application:

```bash
mix deps.get --check-locked
mix deps.tree | rg 'ex_storage_service'
rg -n '"ex_storage_service".*0\.6\.4' mix.lock
! rg -n 'ex_storage_service_s3' mix.exs apps/*/mix.exs mix.lock
```

Expected: the lock check exits `0`; the dependency tree and lock contain `ex_storage_service 0.6.4`; the final negative search exits `0` because no S3 dependency is found. Also add `refute Application.spec(:ex_storage_service_s3)` to `application_test.exs`, which proves the optional application is absent without consulting the network.

- [ ] Run formatting and focused wiring tests:

```bash
mix format mix.exs apps/forge_releases/mix.exs \
  apps/forge_releases/lib/forge_releases/application.ex \
  apps/forge_releases/test/forge_releases/application_test.exs \
  apps/fornacast_web/lib/mix/tasks/fornacast.run.ex \
  apps/fornacast_web/test/fornacast_run_task_test.exs
mix test apps/forge_releases/test/forge_releases/application_test.exs \
  apps/fornacast_web/test/fornacast_run_task_test.exs
```

Expected green result: `0 failures`.

- [ ] Commit the exact dependency and app wiring:

```bash
git add mix.exs mix.lock apps/forge_releases \
  apps/fornacast_web/lib/mix/tasks/fornacast.run.ex \
  apps/fornacast_web/test/fornacast_run_task_test.exs
git commit -m "build(releases): add exact LocalCAS dependency"
```

### Task 3: Configure Concord VSR and the disabled ESS instance in every environment

**Files:**

- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Modify: `apps/fornacast/lib/fornacast/config.ex`
- Create: `apps/forge_releases/test/forge_releases/asset_storage/config_test.exs`

- [ ] Add a red configuration contract test:

```elixir
defmodule ForgeReleases.AssetStorage.ConfigTest do
  use ExUnit.Case, async: true

  alias ExStorageService.InstanceConfig
  alias Fornacast.Config

  @workers [
    :multipart_gc,
    :content_gc,
    :cas_gc,
    :packer,
    :lifecycle,
    :cross_cluster_replication,
    :repair,
    :scrub
  ]

  test "test environment has one exact, listener-free LocalCAS instance" do
    root = Config.release_asset_storage_root()

    assert Path.type(root) == :absolute
    assert root == Path.expand("tmp/test/release-assets")
    assert Config.release_asset_max_bytes() == 2_147_483_648
    assert Config.release_asset_gc_grace_seconds() == 86_400

    assert {:ok, instance} = InstanceConfig.from_application_env()
    assert instance.instance == :fornacast_release_assets
    assert instance.mode == :standalone
    assert instance.node_role == :data
    refute instance.auto_start
    refute instance.web_enabled
    refute instance.public_s3_enabled
    refute instance.cluster_data_plane_enabled
    assert Enum.all?(@workers, &(instance.workers[&1] == false))

    assert instance.data_root == root
    assert instance.blob_root == Path.join(root, "cas")
    assert instance.tmp_root == Path.join(root, "tmp")
    assert instance.ra_root == Path.join(root, "ra")
    assert instance.metadata_root == Path.join(root, "concord")
  end

  test "Concord uses the singleton VSR while retaining Turso ConfigStore" do
    concord = Application.fetch_env!(:concord, :vsr)

    assert Application.fetch_env!(:concord, :cluster_enabled)
    assert Application.fetch_env!(:concord, :data_dir) ==
             Path.join(Config.release_asset_storage_root(), "concord")

    assert concord == [
             group_id: :ex_storage_service_metadata,
             replica_id: node(),
             members: [%{id: node(), endpoint: node()}],
             storage: :file,
             bootstrap: false
           ]

    assert Application.fetch_env!(:concord, :turso)[:enabled]
  end
end
```

- [ ] Run the focused test before adding configuration:

```bash
mix test apps/forge_releases/test/forge_releases/asset_storage/config_test.exs
```

Expected red result: undefined `Fornacast.Config` accessors and missing ESS/VSR configuration.

- [ ] At the top of `config/config.exs`, after `import Config`, derive the environment default and parse the bounded values. Keep the parsing local because compiled modules are unavailable while Mix evaluates config:

```elixir
release_asset_default_root =
  case config_env() do
    :prod -> "/data/release-assets"
    :test -> "tmp/test/release-assets"
    _ -> "tmp/release-assets"
  end

release_asset_root =
  System.get_env("FORNACAST_RELEASE_ASSET_STORAGE_ROOT", release_asset_default_root)
  |> Path.expand()

parse_positive_integer! = fn name, default, minimum, maximum ->
  raw = System.get_env(name, Integer.to_string(default))

  case Integer.parse(raw) do
    {value, ""} when value >= minimum -> min(value, maximum)
    _ -> raise "#{name} must be a decimal integer >= #{minimum}"
  end
end

release_asset_max_bytes =
  parse_positive_integer!.(
    "FORNACAST_RELEASE_ASSET_MAX_BYTES",
    2_147_483_648,
    1,
    2_147_483_648
  )

release_asset_gc_grace_seconds =
  parse_positive_integer!.(
    "FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS",
    86_400,
    3_600,
    2_147_483_647
  )
```

- [ ] Add the Fornacast values and replace the existing non-cluster Concord block. Preserve its existing `turso:` keyword values exactly:

```elixir
config :fornacast,
  release_asset_storage_root: release_asset_root,
  release_asset_max_bytes: release_asset_max_bytes,
  release_asset_gc_grace_seconds: release_asset_gc_grace_seconds

config :concord,
  cluster_enabled: true,
  data_dir: Path.join(release_asset_root, "concord"),
  vsr: [
    group_id: :ex_storage_service_metadata,
    replica_id: node(),
    members: [%{id: node(), endpoint: node()}],
    storage: :file,
    bootstrap: false
  ],
  turso: [
    enabled: config_store_enabled,
    database: System.get_env("FORNACAST_CONFIG_DATABASE_PATH", "fornacast_config_dev.db"),
    pool_size: String.to_integer(System.get_env("FORNACAST_CONFIG_POOL_SIZE", "1")),
    remote_url:
      System.get_env("FORNACAST_CONFIG_TURSO_DATABASE_URL") ||
        System.get_env("CONCORD_TURSO_REMOTE_URL"),
    auth_token:
      System.get_env("FORNACAST_CONFIG_TURSO_AUTH_TOKEN") ||
        System.get_env("CONCORD_TURSO_AUTH_TOKEN")
  ]

config :ex_storage_service,
  data_root: release_asset_root,
  blob_root: Path.join(release_asset_root, "cas"),
  tmp_root: Path.join(release_asset_root, "tmp"),
  ra_root: Path.join(release_asset_root, "ra"),
  metadata_root: Path.join(release_asset_root, "concord"),
  instance_config: [
    instance: :fornacast_release_assets,
    mode: :standalone,
    node_role: :data,
    auto_start: false,
    web_enabled: false,
    public_s3_enabled: false,
    cluster_data_plane_enabled: false,
    workers: %{
      multipart_gc: false,
      content_gc: false,
      cas_gc: false,
      packer: false,
      lifecycle: false,
      cross_cluster_replication: false,
      repair: false,
      scrub: false
    }
  ]
```

- [ ] In `config/test.exs`, retain the existing Turso database path and pool settings but replace `cluster_enabled: false` with the same VSR keys rooted at `tmp/test/release-assets/concord`:

```elixir
release_asset_root = Path.expand("tmp/test/release-assets", test_root)

config :fornacast, release_asset_storage_root: release_asset_root

config :concord,
  cluster_enabled: true,
  data_dir: Path.join(release_asset_root, "concord"),
  vsr: [
    group_id: :ex_storage_service_metadata,
    replica_id: node(),
    members: [%{id: node(), endpoint: node()}],
    storage: :file,
    bootstrap: false
  ],
  turso: [
    enabled: true,
    database:
      System.get_env("FORNACAST_TEST_CONFIG_DATABASE_PATH", "fornacast_config_test.db")
      |> Path.expand(test_root),
    pool_size: 1
  ]
```

- [ ] In the production branch of `config/runtime.exs`, parse the three environment values with the same rules, then override all three application blocks together. This is the complete production storage fragment; keep the existing production Turso values in `fornacast_config_store_options`:

```elixir
release_asset_root =
  System.get_env("FORNACAST_RELEASE_ASSET_STORAGE_ROOT", "/data/release-assets")
  |> Path.expand()

parse_positive_integer! = fn name, default, minimum, maximum ->
  raw = System.get_env(name, Integer.to_string(default))

  case Integer.parse(raw) do
    {value, ""} when value >= minimum -> min(value, maximum)
    _ -> raise "#{name} must be a decimal integer >= #{minimum}"
  end
end

release_asset_max_bytes =
  parse_positive_integer!.(
    "FORNACAST_RELEASE_ASSET_MAX_BYTES",
    2_147_483_648,
    1,
    2_147_483_648
  )

release_asset_gc_grace_seconds =
  parse_positive_integer!.(
    "FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS",
    86_400,
    3_600,
    2_147_483_647
  )

config :fornacast,
  release_asset_storage_root: release_asset_root,
  release_asset_max_bytes: release_asset_max_bytes,
  release_asset_gc_grace_seconds: release_asset_gc_grace_seconds

config :concord,
  cluster_enabled: true,
  data_dir: Path.join(release_asset_root, "concord"),
  vsr: [
    group_id: :ex_storage_service_metadata,
    replica_id: node(),
    members: [%{id: node(), endpoint: node()}],
    storage: :file,
    bootstrap: false
  ],
  turso: fornacast_config_store_options

config :ex_storage_service,
  data_root: release_asset_root,
  blob_root: Path.join(release_asset_root, "cas"),
  tmp_root: Path.join(release_asset_root, "tmp"),
  ra_root: Path.join(release_asset_root, "ra"),
  metadata_root: Path.join(release_asset_root, "concord"),
  instance_config: [
    instance: :fornacast_release_assets,
    mode: :standalone,
    node_role: :data,
    auto_start: false,
    web_enabled: false,
    public_s3_enabled: false,
    cluster_data_plane_enabled: false,
    workers: %{
      multipart_gc: false,
      content_gc: false,
      cas_gc: false,
      packer: false,
      lifecycle: false,
      cross_cluster_replication: false,
      repair: false,
      scrub: false
    }
  ]
```

Use a concrete variable assignment immediately before the block rather than duplicating values:

```elixir
fornacast_config_store_options = [
  enabled: config_store_enabled,
  database: System.get_env("FORNACAST_CONFIG_DATABASE_PATH", "/data/fornacast_config.db"),
  pool_size: String.to_integer(System.get_env("FORNACAST_CONFIG_POOL_SIZE") || "1"),
  remote_url:
    System.get_env("FORNACAST_CONFIG_TURSO_DATABASE_URL") ||
      System.get_env("CONCORD_TURSO_REMOTE_URL"),
  auth_token: config_store_auth_token
]
```

- [ ] Add public parsed-value accessors to `Fornacast.Config`:

```elixir
def release_asset_storage_root do
  :fornacast
  |> Application.fetch_env!(:release_asset_storage_root)
  |> Path.expand()
end

def release_asset_max_bytes do
  Application.fetch_env!(:fornacast, :release_asset_max_bytes)
end

def release_asset_gc_grace_seconds do
  Application.fetch_env!(:fornacast, :release_asset_gc_grace_seconds)
end
```

- [ ] Format and run the focused configuration contract:

```bash
mix format config/config.exs config/runtime.exs config/test.exs \
  apps/fornacast/lib/fornacast/config.ex \
  apps/forge_releases/test/forge_releases/asset_storage/config_test.exs
mix test apps/forge_releases/test/forge_releases/asset_storage/config_test.exs
```

Expected green result: `0 failures`; logs may mention the configured release-asset and Concord roots but must not print credentials.

- [ ] Commit the complete pre-start configuration contract:

```bash
git add config/config.exs config/runtime.exs config/test.exs \
  apps/fornacast/lib/fornacast/config.ex \
  apps/forge_releases/test/forge_releases/asset_storage/config_test.exs
git commit -m "config(releases): define embedded LocalCAS instance"
```

### Task 4: Validate storage roots with real write, sync, close, and remove probes

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/asset_storage/config.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_storage/file_system.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex`
- Modify: `apps/forge_releases/test/forge_releases/asset_storage/config_test.exs`
- Create: `apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs`

- [ ] Add red tests for exact configuration loading, containment, same-filesystem validation, symlink rejection, and a failing file-sync probe:

```elixir
defmodule ForgeReleases.AssetStorage.LocalCASTest do
  use ExUnit.Case, async: true

  alias ForgeReleases.AssetStorage.{Config, FileSystem, LocalCAS}

  defmodule SyncFailureFS do
    defdelegate mkdir_p(path), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate lstat(path), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate stat(path), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate open(path, modes), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate write(io, data), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate close(io), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate rm(path), to: ForgeReleases.AssetStorage.FileSystem
    def sync(_io), do: {:error, :eio}
  end

  defmodule DeviceMismatchFS do
    defdelegate mkdir_p(path), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate lstat(path), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate open(path, modes), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate write(io, data), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate sync(io), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate close(io), to: ForgeReleases.AssetStorage.FileSystem
    defdelegate rm(path), to: ForgeReleases.AssetStorage.FileSystem

    def stat(path) do
      with {:ok, stat} <- ForgeReleases.AssetStorage.FileSystem.stat(path) do
        if Path.basename(path) == "tmp" do
          {:ok, %{stat | minor_device: stat.minor_device + 1}}
        else
          {:ok, stat}
        end
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "fornacast-localcas-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "loads the exact validated ESS context" do
    config = Config.load!()

    assert config.root == Fornacast.Config.release_asset_storage_root()
    assert config.instance_config.instance == :fornacast_release_assets
    assert config.context.blob_root == config.blob_root
    assert config.context.tmp_root == config.tmp_root
    assert config.max_bytes == Fornacast.Config.release_asset_max_bytes()
  end

  test "preflight writes, syncs, closes, and removes contained probes", %{root: root} do
    config = Config.for_root!(root, max_bytes: 1024, gc_grace_seconds: 3_600)
    assert :ok = LocalCAS.preflight(config)
    assert File.ls!(config.blob_root) == []
    assert File.ls!(config.tmp_root) == []
  end

  test "preflight fails when a file cannot be synced", %{root: root} do
    config = Config.for_root!(root, max_bytes: 1024, gc_grace_seconds: 3_600)

    assert_raise ArgumentError, ~r/storage write probe failed.*eio/, fn ->
      LocalCAS.preflight(config, SyncFailureFS)
    end
  end

  test "configuration rejects roots outside the storage root", %{root: root} do
    assert_raise ArgumentError, ~r/blob_root must be contained/, fn ->
      Config.validate!(%Config{
        root: root,
        data_root: root,
        blob_root: Path.join(Path.dirname(root), "outside"),
        tmp_root: Path.join(root, "tmp"),
        ra_root: Path.join(root, "ra"),
        metadata_root: Path.join(root, "concord"),
        max_bytes: 1024,
        gc_grace_seconds: 3_600
      })
    end
  end

  test "preflight rejects symlinked root components", %{root: root} do
    target = Path.join(root, "target")
    link = Path.join(root, "linked-cas")
    File.mkdir_p!(target)
    File.ln_s!(target, link)

    config =
      root
      |> Config.for_root!(max_bytes: 1024, gc_grace_seconds: 3_600)
      |> Map.put(:blob_root, link)

    assert_raise ArgumentError, ~r/symlink/, fn -> LocalCAS.preflight(config) end
  end

  test "preflight rejects an intermediate symlink before creating outside it", %{root: root} do
    target = Path.join(root, "target")
    link = Path.join(root, "linked")
    File.mkdir_p!(target)
    File.ln_s!(target, link)

    config =
      Config.for_root!(
        Path.join(link, "must-not-be-created"),
        max_bytes: 1024,
        gc_grace_seconds: 3_600
      )

    assert_raise ArgumentError, ~r/symlink/, fn -> LocalCAS.preflight(config) end
    refute File.exists?(Path.join(target, "must-not-be-created"))
  end

  test "preflight rejects cross-device publication", %{root: root} do
    config = Config.for_root!(root, max_bytes: 1024, gc_grace_seconds: 3_600)

    assert_raise ArgumentError, ~r/must share a filesystem/, fn ->
      LocalCAS.preflight(config, DeviceMismatchFS)
    end
  end

  test "capacity parser accepts GNU and macOS df layouts" do
    gnu_bytes = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/root 1000 750 250 75% /
    """

    gnu_inodes = """
    Filesystem Inodes IUsed IFree IUse% Mounted on
    /dev/root 1000 600 400 60% /
    """

    macos_bytes = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk3s1 2000 500 1500 25% /
    """

    macos_inodes = """
    Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on
    /dev/disk3s1 2000 500 1500 25% 20 180 10% /
    """

    assert {:ok, %{total: 1_024_000, available: 256_000}} =
             FileSystem.parse_df_metric(gnu_bytes, :bytes)

    assert {:ok, %{total: 1_000, available: 400}} =
             FileSystem.parse_df_metric(gnu_inodes, :inodes)

    assert {:ok, %{total: 2_048_000, available: 1_536_000}} =
             FileSystem.parse_df_metric(macos_bytes, :bytes)

    assert {:ok, %{total: 200, available: 180}} =
             FileSystem.parse_df_metric(macos_inodes, :inodes)
  end
end
```

- [ ] Run the focused tests and confirm the foundation modules are absent:

```bash
mix test apps/forge_releases/test/forge_releases/asset_storage/config_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs
```

Expected red result: compile errors for `ForgeReleases.AssetStorage.Config`, `FileSystem`, and `LocalCAS`.

- [ ] Implement the immutable configuration value. `load!/0` must use `InstanceConfig.from_application_env/0` and `ExStorageService.context/1`; `for_root!/2` is a test helper that constructs the same root layout without mutating application env:

```elixir
defmodule ForgeReleases.AssetStorage.Config do
  @moduledoc false

  alias ExStorageService.InstanceConfig

  @enforce_keys [
    :root,
    :data_root,
    :blob_root,
    :tmp_root,
    :ra_root,
    :metadata_root,
    :max_bytes,
    :gc_grace_seconds
  ]
  defstruct @enforce_keys ++ [:instance_config, :context]

  @type t :: %__MODULE__{}

  def load! do
    root = Fornacast.Config.release_asset_storage_root()
    {:ok, instance_config} = InstanceConfig.from_application_env()
    {:ok, context} = ExStorageService.context(instance_config)

    validate!(%__MODULE__{
      root: root,
      data_root: context.data_root,
      blob_root: context.blob_root,
      tmp_root: context.tmp_root,
      ra_root: context.ra_root,
      metadata_root: context.metadata_root,
      max_bytes: Fornacast.Config.release_asset_max_bytes(),
      gc_grace_seconds: Fornacast.Config.release_asset_gc_grace_seconds(),
      instance_config: instance_config,
      context: context
    })
  end

  @doc false
  def for_root!(root, options) when is_binary(root) and is_list(options) do
    root = Path.expand(root)

    validate!(%__MODULE__{
      root: root,
      data_root: root,
      blob_root: Path.join(root, "cas"),
      tmp_root: Path.join(root, "tmp"),
      ra_root: Path.join(root, "ra"),
      metadata_root: Path.join(root, "concord"),
      max_bytes: Keyword.fetch!(options, :max_bytes),
      gc_grace_seconds: Keyword.fetch!(options, :gc_grace_seconds)
    })
  end

  def validate!(%__MODULE__{} = config) do
    if Path.type(config.root) != :absolute,
      do: raise(ArgumentError, "release-asset root must be absolute")

    for {name, path} <- [
          data_root: config.data_root,
          blob_root: config.blob_root,
          tmp_root: config.tmp_root,
          ra_root: config.ra_root,
          metadata_root: config.metadata_root
        ] do
      unless contained?(config.root, path) do
        raise ArgumentError, "#{name} must be contained by the release-asset root"
      end
    end

    unless is_integer(config.max_bytes) and config.max_bytes in 1..2_147_483_648,
      do: raise(ArgumentError, "release-asset maximum must be in 1..2147483648")

    unless is_integer(config.gc_grace_seconds) and config.gc_grace_seconds >= 3_600,
      do: raise(ArgumentError, "release-asset GC grace must be at least 3600 seconds")

    config
  end

  defp contained?(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    relative = Path.relative_to(path, root)
    relative == "." or (relative != path and relative != ".." and not String.starts_with?(relative, "../"))
  end
end
```

- [ ] Implement the small filesystem seam used for boot validation and later fd consumption:

```elixir
defmodule ForgeReleases.AssetStorage.FileSystem do
  @moduledoc false

  def mkdir_p(path), do: File.mkdir_p(path)
  def lstat(path), do: File.lstat(path)
  def stat(path), do: File.stat(path)
  def open(path, modes), do: :file.open(String.to_charlist(path), modes)
  def write(io, data), do: :file.write(io, data)
  def sync(io), do: :file.sync(io)
  def close(io), do: :file.close(io)
  def rm(path), do: File.rm(path)
  def read_file_info(io), do: :file.read_file_info(io)
  def pread(io, offset, length), do: :file.pread(io, offset, length)

  def filesystem_capacity(path) do
    with {:ok, bytes} <- df_metric(path, "-Pk", :bytes),
         {:ok, inodes} <- df_metric(path, "-Pi", :inodes) do
      {:ok, %{bytes: bytes, inodes: inodes}}
    end
  end

  defp df_metric(path, flag, metric) do
    case System.cmd("df", [flag, path],
           env: [{"LC_ALL", "C"}],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_df_metric(output, metric)
      {_output, _status} -> {:error, :capacity_unavailable}
    end
  rescue
    _error -> {:error, :capacity_unavailable}
  end

  @doc false
  def parse_df_metric(output, :bytes) do
    with {:ok, headers, fields} <- parse_df_table(output),
         {total_index, unit} <- block_column(headers),
         available_index when is_integer(available_index) <-
           header_index(headers, ["available"]),
         {:ok, total} <- integer_at(fields, total_index),
         {:ok, available} <- integer_at(fields, available_index),
         true <- total >= 0 and available >= 0 and available <= total do
      {:ok, %{total: total * unit, available: available * unit}}
    else
      _invalid -> {:error, :capacity_unavailable}
    end
  end

  def parse_df_metric(output, :inodes) do
    with {:ok, headers, fields} <- parse_df_table(output),
         available_index when is_integer(available_index) <-
           header_index(headers, ["ifree"]),
         {:ok, available} <- integer_at(fields, available_index),
         {:ok, total} <- inode_total(headers, fields, available),
         true <- total >= 0 and available >= 0 and available <= total do
      {:ok, %{total: total, available: available}}
    else
      _invalid -> {:error, :capacity_unavailable}
    end
  end

  def parse_df_metric(_output, _metric), do: {:error, :capacity_unavailable}

  defp parse_df_table(output) do
    case String.split(output, "\n", trim: true) do
      [header | rows] when rows != [] ->
        {:ok, String.split(header, ~r/\s+/, trim: true), rows |> List.last() |> String.split(~r/\s+/, trim: true)}

      _invalid ->
        {:error, :capacity_unavailable}
    end
  end

  defp block_column(headers) do
    headers
    |> Enum.with_index()
    |> Enum.find_value(fn {header, index} ->
      case String.downcase(header) do
        "1024-blocks" -> {index, 1_024}
        "1k-blocks" -> {index, 1_024}
        "512-blocks" -> {index, 512}
        _other -> nil
      end
    end)
  end

  defp inode_total(headers, fields, available) do
    case header_index(headers, ["inodes"]) do
      index when is_integer(index) ->
        integer_at(fields, index)

      nil ->
        with index when is_integer(index) <- header_index(headers, ["iused"]),
             {:ok, used} <- integer_at(fields, index) do
          {:ok, used + available}
        else
          _invalid -> {:error, :capacity_unavailable}
        end
    end
  end

  defp header_index(headers, names) do
    Enum.find_index(headers, &(String.downcase(&1) in names))
  end

  defp integer_at(fields, index) do
    case Enum.at(fields, index) do
      nil -> {:error, :capacity_unavailable}
      value ->
        case Integer.parse(value) do
          {integer, ""} -> {:ok, integer}
          _invalid -> {:error, :capacity_unavailable}
        end
    end
  end
end
```

`df -P` is invoked under `LC_ALL=C` with the validated internal root as a single
argv entry on the supported macOS/Linux operator platforms. The parser keys off
the actual block/inode headers: GNU's explicit `Inodes` total and macOS's
`iused + ifree` layout are both covered by fixtures. Neither a mountpoint/path
nor raw output crosses `LocalCAS`; parse, executable, and exit failures
normalize to `:unavailable`.

- [ ] Add strict root preflight to `LocalCAS`. Probe exactly the mutable CAS and temporary roots, after validating every existing path component is not a symlink and that publication is same-device:

```elixir
defmodule ForgeReleases.AssetStorage.LocalCAS do
  @moduledoc false

  alias ForgeReleases.AssetStorage.{Config, FileSystem}

  @spec preflight(Config.t(), module()) :: :ok
  def preflight(%Config{} = config, fs \\ FileSystem) do
    Config.validate!(config)

    for root <- [config.root, config.blob_root, config.tmp_root] do
      reject_existing_symlinks!(fs, root)
      mkdir!(fs, root)
      reject_symlinks!(fs, root)
    end

    assert_same_device!(fs, config.blob_root, config.tmp_root)

    for root <- [config.blob_root, config.tmp_root] do
      probe_write_sync_remove!(fs, root)
    end

    :ok
  end

  defp mkdir!(fs, path) do
    case fs.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "cannot create storage root #{path}: #{inspect(reason)}"
    end
  end

  defp reject_existing_symlinks!(fs, path) do
    path
    |> Path.split()
    |> Enum.reduce_while("/", fn segment, parent ->
      current = if segment == "/", do: "/", else: Path.join(parent, segment)

      case fs.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} ->
          raise ArgumentError, "storage root contains symlink component: #{current}"

        {:ok, %File.Stat{}} ->
          {:cont, current}

        {:error, :enoent} ->
          {:halt, current}

        {:error, reason} ->
          raise ArgumentError, "cannot inspect storage root #{current}: #{inspect(reason)}"
      end
    end)

    :ok
  end

  defp reject_symlinks!(fs, path) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn segment, parent ->
      current = if segment == "/", do: "/", else: Path.join(parent, segment)

      case fs.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} ->
          raise ArgumentError, "storage root contains symlink component: #{current}"

        {:ok, %File.Stat{}} ->
          current

        {:error, reason} ->
          raise ArgumentError, "cannot inspect storage root #{current}: #{inspect(reason)}"
      end

      current
    end)

    :ok
  end

  defp assert_same_device!(fs, left, right) do
    with {:ok, %File.Stat{major_device: major, minor_device: minor}} <- fs.stat(left),
         {:ok, %File.Stat{major_device: ^major, minor_device: ^minor}} <- fs.stat(right) do
      :ok
    else
      _ -> raise ArgumentError, "CAS and temporary roots must share a filesystem"
    end
  end

  defp probe_write_sync_remove!(fs, root) do
    path =
      Path.join(root, ".fornacast-write-probe-#{System.unique_integer([:positive, :monotonic])}")

    result =
      with {:ok, io} <- fs.open(path, [:write, :raw, :binary, :exclusive]) do
        write_result = with :ok <- fs.write(io, <<0>>), do: fs.sync(io)
        close_result = fs.close(io)
        remove_result = fs.rm(path)

        case {write_result, close_result, remove_result} do
          {:ok, :ok, :ok} -> :ok
          {{:error, reason}, _, _} -> {:error, reason}
          {_, {:error, reason}, _} -> {:error, reason}
          {_, _, {:error, reason}} -> {:error, reason}
        end
      end

    case result do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "storage write probe failed for #{root}: #{inspect(reason)}"
    end
  end
end
```

- [ ] Run the focused root tests, including the real filesystem probe:

```bash
mix format apps/forge_releases/lib/forge_releases/asset_storage/config.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/file_system.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex \
  apps/forge_releases/test/forge_releases/asset_storage/config_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs
mix test apps/forge_releases/test/forge_releases/asset_storage/config_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs
```

Expected green result: `0 failures`; neither root retains a `.fornacast-write-probe-*` file.

- [ ] Commit the fail-fast configuration and root proof:

```bash
git add apps/forge_releases/lib/forge_releases/asset_storage/config.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/file_system.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex \
  apps/forge_releases/test/forge_releases/asset_storage/config_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs
git commit -m "feat(releases): validate LocalCAS roots at boot"
```

### Task 5: Supervise one temporary ESS instance with readiness and bounded restart

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/asset_storage/supervisor.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_storage/manager.ex`
- Modify: `apps/forge_releases/lib/forge_releases/application.ex`
- Modify: `apps/forge_releases/test/forge_releases/application_test.exs`
- Create: `apps/forge_releases/test/forge_releases/asset_storage/manager_test.exs`

- [ ] Add red supervision tests. Run them synchronously because they kill and observe the single application-owned instance:

```elixir
defmodule ForgeReleases.AssetStorage.ManagerTest do
  use ExUnit.Case, async: false

  alias ExStorageService.Names
  alias ForgeReleases.AssetStorage.Manager

  test "the exact instance is ready with only its Engine child" do
    assert Manager.status() == :ready
    assert Manager.ready?()

    instance = GenServer.whereis(Names.instance_supervisor(:fornacast_release_assets))
    assert is_pid(instance)

    assert [{_id, engine, :worker, [ExStorageService.Storage.Engine]}] =
             Supervisor.which_children(instance)

    assert is_pid(engine)
    refute Application.spec(:ex_storage_service_s3)
  end

  test "the ESS child spec is temporary with a bounded shutdown" do
    config = ForgeReleases.AssetStorage.Config.load!()
    spec = Manager.instance_child_spec(config.instance_config)

    assert spec.restart == :temporary
    assert spec.shutdown == 30_000
  end

  test "instance loss becomes not-ready and is restarted without app loss" do
    old_instance = GenServer.whereis(Names.instance_supervisor(:fornacast_release_assets))
    Process.exit(old_instance, :kill)

    assert_eventually(fn -> match?({:not_ready, _}, Manager.status()) end)

    assert_eventually(fn ->
      new_instance = GenServer.whereis(Names.instance_supervisor(:fornacast_release_assets))
      is_pid(new_instance) and new_instance != old_instance and Manager.ready?()
    end)
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition did not become true before timeout")
      true ->
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
    end
  end
end
```

Extend `application_test.exs` with the application ownership assertion:

```elixir
test "forge_releases owns the storage subtree" do
  assert Process.whereis(ForgeReleases.Supervisor)
  assert Process.whereis(ForgeReleases.AssetStorage.Supervisor)
  assert Process.whereis(ForgeReleases.AssetStorage.InstanceSupervisor)
  assert Process.whereis(ForgeReleases.AssetStorage.Manager)
end
```

- [ ] Run the focused tests before implementing supervision:

```bash
mix test apps/forge_releases/test/forge_releases/application_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/manager_test.exs
```

Expected red result: missing `AssetStorage.Supervisor` and `AssetStorage.Manager` modules/processes.

- [ ] Make `ForgeReleases.Application` own the storage subtree:

```elixir
@impl true
def start(_type, _args) do
  children = [ForgeReleases.AssetStorage.Supervisor]
  Supervisor.start_link(children, strategy: :one_for_one, name: ForgeReleases.Supervisor)
end
```

- [ ] Implement the fail-fast outer supervisor. Configuration and both real I/O probes run before any child is returned:

```elixir
defmodule ForgeReleases.AssetStorage.Supervisor do
  @moduledoc false

  use Supervisor

  alias ForgeReleases.AssetStorage.{Config, LocalCAS, Manager}

  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    config = Config.load!()
    :ok = LocalCAS.preflight(config)

    children = [
      {DynamicSupervisor,
       strategy: :one_for_one, name: ForgeReleases.AssetStorage.InstanceSupervisor},
      {Manager, config: config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

- [ ] Implement the manager with only `status/0` and `ready?/0` as public runtime state. It monitors both the top-level instance and its Engine, marks not-ready before each retry, and caps exponential backoff at five seconds:

```elixir
defmodule ForgeReleases.AssetStorage.Manager do
  @moduledoc false

  use GenServer

  alias ExStorageService.Names
  alias ForgeReleases.AssetStorage.Config

  @initial_backoff_ms 100
  @maximum_backoff_ms 5_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec status() :: :ready | {:not_ready, atom()}
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _reason -> {:not_ready, :manager_unavailable}
  end

  @spec ready?() :: boolean()
  def ready?, do: status() == :ready

  @doc false
  def instance_child_spec(instance_config) do
    instance_config
    |> ExStorageService.child_spec()
    |> Supervisor.child_spec(restart: :temporary, shutdown: 30_000)
  end

  @impl true
  def init(options) do
    config = Keyword.fetch!(options, :config)
    state = %{config: config, status: {:not_ready, :starting}, instance_ref: nil, engine_ref: nil, attempt: 0}

    case start_or_attach(state) do
      {:ok, ready} -> {:ok, ready}
      {:error, reason, _state} -> {:stop, {:asset_storage_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{instance_ref: reference} = state) do
    {:noreply, schedule_restart(%{state | instance_ref: nil, engine_ref: nil}, :instance_down)}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{engine_ref: reference} = state) do
    {:noreply, schedule_engine_check(%{state | engine_ref: nil}, :engine_down)}
  end

  def handle_info(:restart_instance, state) do
    case start_or_attach(state) do
      {:ok, ready} -> {:noreply, ready}
      {:error, _reason, failed} -> {:noreply, schedule_restart(failed, :instance_start_failed)}
    end
  end

  def handle_info(:check_engine, state) do
    case attach_engine(state) do
      {:ok, ready} -> {:noreply, ready}
      {:error, failed} -> {:noreply, schedule_engine_check(failed, :engine_not_ready)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_or_attach(%{config: %Config{instance_config: instance_config}} = state) do
    instance_name = Names.instance_supervisor(instance_config.instance)

    result =
      case GenServer.whereis(instance_name) do
        pid when is_pid(pid) -> {:ok, pid}
        nil -> DynamicSupervisor.start_child(ForgeReleases.AssetStorage.InstanceSupervisor, instance_child_spec(instance_config))
      end

    case result do
      {:ok, pid} -> attach_instance(state, pid)
      {:error, {:already_started, pid}} -> attach_instance(state, pid)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp attach_instance(state, instance) do
    instance_ref = Process.monitor(instance)

    case attach_engine(%{state | instance_ref: instance_ref}) do
      {:ok, ready} -> {:ok, ready}
      {:error, failed} ->
        Process.demonitor(instance_ref, [:flush])
        {:error, :engine_not_ready, %{failed | instance_ref: nil}}
    end
  end

  defp attach_engine(%{config: %Config{instance_config: instance_config}} = state) do
    case GenServer.whereis(Names.via(instance_config.instance, :engine)) do
      pid when is_pid(pid) ->
        {:ok, %{state | status: :ready, engine_ref: Process.monitor(pid), attempt: 0}}

      nil ->
        {:error, %{state | status: {:not_ready, :engine_not_ready}}}
    end
  end

  defp schedule_restart(state, reason) do
    Process.send_after(self(), :restart_instance, backoff(state.attempt))
    %{state | status: {:not_ready, reason}, attempt: state.attempt + 1}
  end

  defp schedule_engine_check(state, reason) do
    Process.send_after(self(), :check_engine, backoff(state.attempt))
    %{state | status: {:not_ready, reason}, attempt: state.attempt + 1}
  end

  defp backoff(attempt) do
    min(@initial_backoff_ms * Integer.pow(2, min(attempt, 10)), @maximum_backoff_ms)
  end
end
```

- [ ] Run the focused supervision tests three times to expose registration and restart races:

```bash
mix format apps/forge_releases/lib/forge_releases/application.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/supervisor.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/manager.ex \
  apps/forge_releases/test/forge_releases/application_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/manager_test.exs
mix test apps/forge_releases/test/forge_releases/application_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/manager_test.exs --repeat-until-failure 3
```

Expected green result: all three runs report `0 failures`; killing the temporary child never terminates `ForgeReleases.Supervisor`.

- [ ] Commit the supervision boundary:

```bash
git add apps/forge_releases/lib/forge_releases/application.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/supervisor.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/manager.ex \
  apps/forge_releases/test/forge_releases/application_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage/manager_test.exs
git commit -m "feat(releases): supervise embedded LocalCAS readiness"
```

### Task 6: Implement the opaque streaming LocalCAS adapter

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/asset_storage.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_storage/staged_ref.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_storage/source.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_storage/file_system.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex`
- Modify: `apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs`

- [ ] Add end-to-end red tests for the public contract. Use small chunks while proving state threading, digest publication, range reads, expected-size validation, descriptor ownership, idempotent close, lower-limit enforcement, lowercase keys, and normalized errors:

```elixir
describe "opaque adapter contract" do
  setup do
    key = "contract-#{System.unique_integer([:positive, :monotonic])}"
    %{staging_key: key}
  end

  test "capacity reports only bounded byte and inode counts" do
    assert {:ok, capacity} = ForgeReleases.AssetStorage.capacity()

    for area <- [:cas, :staging] do
      assert %{bytes: bytes, inodes: inodes} = Map.fetch!(capacity, area)
      assert bytes.total >= bytes.available and bytes.available >= 0
      assert inodes.total >= inodes.available and inodes.available >= 0
    end

    refute inspect(capacity) =~ ForgeReleases.AssetStorage.Config.load!().root
    assert {:error, :unavailable} = LocalCAS.capacity(CapacityFailureFS)
  end

  test "stage, commit, stat, ranged fd reads, verify, and delete", %{staging_key: key} do
    assert ForgeReleases.AssetStorage.ready?()

    reader = fn
      %{chunks: [chunk | rest]} = state, read_options ->
        assert read_options[:length] <= 1_048_576
        {:more, chunk, %{state | chunks: rest}}

      %{chunks: []} = state, _read_options ->
        {:done, state}
    end

    state = %{chunks: ["forna", "cast"]}

    assert {:ok, staged, metadata, final_state} =
             ForgeReleases.AssetStorage.stage_from_reader(
               key,
               reader,
               state,
               read_options: [length: 262_144, read_length: 262_144, read_timeout: 1_000]
             )

    digest = :crypto.hash(:sha256, "fornacast") |> Base.encode16(case: :lower)
    assert metadata == %{sha256_digest: digest, storage_key: digest, size: 9}
    assert final_state == %{chunks: []}
    assert inspect(staged) == "#ForgeReleases.AssetStorage.StagedRef<redacted>"

    assert {:ok, ^metadata} = ForgeReleases.AssetStorage.commit(staged)
    assert {:ok, %{storage_key: ^digest, size: 9}} = ForgeReleases.AssetStorage.stat(digest)
    assert :ok = ForgeReleases.AssetStorage.verify(digest)

    assert {:ok, source} = ForgeReleases.AssetStorage.open(digest, 9, {2, 5})
    assert inspect(source) == "#ForgeReleases.AssetStorage.Source<redacted>"
    assert {:ok, "rn", source} = ForgeReleases.AssetStorage.read(source, 2)
    assert {:ok, "aca", source} = ForgeReleases.AssetStorage.read(source, 10)
    assert :eof = ForgeReleases.AssetStorage.read(source, 1)
    assert :ok = ForgeReleases.AssetStorage.close(source)
    assert :ok = ForgeReleases.AssetStorage.close(source)

    assert :ok = ForgeReleases.AssetStorage.delete(digest)
    assert {:error, :not_found} = ForgeReleases.AssetStorage.stat(digest)
  end

  test "open owns an fd and validates the recorded size", %{staging_key: key} do
    reader = fn state, _options -> {:ok, "descriptor", state} end

    assert {:ok, staged, %{storage_key: digest}, :state} =
             ForgeReleases.AssetStorage.stage_from_reader(
               key,
               reader,
               :state,
               read_options: [length: 32, read_length: 32, read_timeout: 1_000]
             )

    assert {:ok, _metadata} = ForgeReleases.AssetStorage.commit(staged)
    assert {:error, :integrity_mismatch} = ForgeReleases.AssetStorage.open(digest, 99, :all)
    assert {:ok, source} = ForgeReleases.AssetStorage.open(digest, 10, :all)

    assert :ok = ForgeReleases.AssetStorage.delete(digest)
    assert {:ok, "descriptor", source} = ForgeReleases.AssetStorage.read(source, 1_048_577)
    assert :eof = ForgeReleases.AssetStorage.read(source, 1)
    assert :ok = ForgeReleases.AssetStorage.close(source)
  end

  test "effective lower maximum and caller input are enforced", %{staging_key: key} do
    reader = fn state, _options -> {:ok, "four", state + 1} end

    assert {:error, :entity_too_large, 1} =
             ForgeReleases.AssetStorage.stage_from_reader(
               key,
               reader,
               0,
               max_size: 3,
               read_options: [length: 3, read_length: 3, read_timeout: 1_000]
             )

    assert {:error, :invalid_source, 0} =
             ForgeReleases.AssetStorage.stage_from_reader(
               "../escape",
               reader,
               0,
               read_options: [length: 3, read_length: 3, read_timeout: 1_000]
             )

    uppercase = String.duplicate("A", 64)
    assert {:error, :invalid_source} = ForgeReleases.AssetStorage.stat(uppercase)
    assert {:error, :invalid_source} = ForgeReleases.AssetStorage.open(uppercase, 1, :all)
  end
end

describe "staged survivor recovery boundary" do
  setup do
    key = "survivor-#{System.unique_integer([:positive, :monotonic])}"
    config = ForgeReleases.AssetStorage.Config.load!()
    directory = Path.join([config.tmp_root, "uploads", key])
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{key: key, directory: directory}
  end

  test "recovers one direct regular survivor and cleans it without recursion", context do
    path = Path.join(context.directory, "upload-1")
    File.write!(path, "survivor")
    digest = :crypto.hash(:sha256, "survivor") |> Base.encode16(case: :lower)

    assert {:ok, staged} =
             ForgeReleases.AssetStorage.recover_stage(context.key, digest, 8)

    assert inspect(staged) == "#ForgeReleases.AssetStorage.StagedRef<redacted>"
    assert {:ok, %{sha256_digest: ^digest, storage_key: ^digest, size: 8}} =
             ForgeReleases.AssetStorage.commit(staged)
    assert :ok = ForgeReleases.AssetStorage.cleanup_staging(context.key)
    refute File.exists?(context.directory)
    assert :ok = ForgeReleases.AssetStorage.cleanup_staging(context.key)
  end

  test "rejects missing, symlinked, nested, multiple, size, and digest mismatches", context do
    assert :ok = ForgeReleases.AssetStorage.cleanup_staging(context.key)
    assert {:error, :not_found} =
             ForgeReleases.AssetStorage.recover_stage(context.key, String.duplicate("a", 64), 1)

    File.mkdir_p!(context.directory)
    File.write!(Path.join(context.directory, "one"), "a")
    File.write!(Path.join(context.directory, "two"), "b")

    assert {:error, :invalid_source} =
             ForgeReleases.AssetStorage.recover_stage(context.key, String.duplicate("a", 64), 1)

    File.rm_rf!(context.directory)
    File.mkdir_p!(Path.join(context.directory, "nested"))

    assert {:error, :invalid_source} =
             ForgeReleases.AssetStorage.recover_stage(context.key, String.duplicate("a", 64), 1)

    File.rm_rf!(context.directory)
    File.mkdir_p!(context.directory)
    target = Path.join(context.directory, "target")
    File.write!(target, "a")
    File.ln_s!(target, Path.join(context.directory, "link"))
    File.rm!(target)

    assert {:error, :invalid_source} =
             ForgeReleases.AssetStorage.recover_stage(context.key, String.duplicate("a", 64), 1)

    File.rm_rf!(context.directory)
    File.mkdir_p!(context.directory)
    File.write!(Path.join(context.directory, "one"), "short")

    assert {:error, :integrity_mismatch} =
             ForgeReleases.AssetStorage.recover_stage(context.key, String.duplicate("a", 64), 99)

    assert {:error, :integrity_mismatch} =
             ForgeReleases.AssetStorage.recover_stage(context.key, String.duplicate("a", 64), 5)
  end

  test "effective configured cap applies to survivors", context do
    previous = Application.fetch_env!(:fornacast, :release_asset_max_bytes)
    Application.put_env(:fornacast, :release_asset_max_bytes, 4)
    on_exit(fn -> Application.put_env(:fornacast, :release_asset_max_bytes, previous) end)
    File.write!(Path.join(context.directory, "upload-1"), "12345")

    assert {:error, :entity_too_large} =
             ForgeReleases.AssetStorage.recover_stage(context.key, String.duplicate("a", 64), 5)
  end

  test "cleanup refuses a symlinked staging directory without touching its target", context do
    File.rm_rf!(context.directory)
    target = Path.join(System.tmp_dir!(), "cleanup-target-#{System.unique_integer([:positive])}")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "keep"), "kept")
    File.ln_s!(target, context.directory)
    on_exit(fn -> File.rm_rf!(target) end)

    assert {:error, :invalid_source} =
             ForgeReleases.AssetStorage.cleanup_staging(context.key)

    assert File.read!(Path.join(target, "keep")) == "kept"
  end
end
```

At the top of this test module, use `async: false` because the cap test temporarily changes one application value:

```elixir
use ExUnit.Case, async: false

defmodule CapacityFailureFS do
  def filesystem_capacity(_path), do: {:error, :eio}
end
```

- [ ] Run the focused adapter test and confirm its public modules are missing:

```bash
mix test apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs
```

Expected red result: undefined `ForgeReleases.AssetStorage` functions and missing opaque handle modules.

- [ ] Define the small domain-facing behavior and fixed facade. `options` accepts only `:max_size` and `:read_options`; it never accepts roots, a bucket, filesystem modules, pack modules, or ESS faults:

```elixir
defmodule ForgeReleases.AssetStorage do
  @moduledoc false

  alias ForgeReleases.AssetStorage.{LocalCAS, Manager, Source, StagedRef}

  @type storage_key :: String.t()
  @type storage_error ::
          :not_found
          | :entity_too_large
          | :invalid_source
          | :integrity_mismatch
          | :ambiguous_commit
          | :busy_deleting
          | :unavailable
  @type metadata :: %{sha256_digest: storage_key(), storage_key: storage_key(), size: non_neg_integer()}
  @type capacity_metric :: %{total: non_neg_integer(), available: non_neg_integer()}
  @type filesystem_capacity :: %{bytes: capacity_metric(), inodes: capacity_metric()}
  @type capacity :: %{cas: filesystem_capacity(), staging: filesystem_capacity()}

  @callback stage_from_reader(String.t(), function(), state, keyword()) ::
              {:ok, StagedRef.t(), metadata(), state}
              | {:error, storage_error(), state}
            when state: term()
  @callback commit(StagedRef.t()) :: {:ok, metadata()} | {:error, storage_error()}
  @callback discard(StagedRef.t()) :: :ok | {:error, storage_error()}
  @callback stat(storage_key()) ::
              {:ok, %{storage_key: storage_key(), size: non_neg_integer()}}
              | {:error, storage_error()}
  @callback open(storage_key(), non_neg_integer(), :all | {non_neg_integer(), non_neg_integer()}) ::
              {:ok, Source.t()} | {:error, storage_error()}
  @callback recover_stage(String.t(), storage_key(), non_neg_integer()) ::
              {:ok, StagedRef.t()} | {:error, storage_error()}
  @callback cleanup_staging(String.t()) :: :ok | {:error, storage_error()}
  @callback read(Source.t(), pos_integer()) ::
              {:ok, binary(), Source.t()} | :eof | {:error, storage_error()}
  @callback close(Source.t()) :: :ok
  @callback verify(storage_key()) :: :ok | {:error, storage_error()}
  @callback delete(storage_key()) :: :ok | {:error, storage_error()}
  @callback capacity() :: {:ok, capacity()} | {:error, storage_error()}

  @spec ready?() :: boolean()
  def ready?, do: Manager.ready?()

  defdelegate stage_from_reader(staging_key, reader, state, options), to: LocalCAS
  defdelegate commit(staged_ref), to: LocalCAS
  defdelegate discard(staged_ref), to: LocalCAS
  defdelegate stat(storage_key), to: LocalCAS
  defdelegate open(storage_key, expected_size, range), to: LocalCAS
  defdelegate recover_stage(staging_key, expected_digest, expected_size), to: LocalCAS
  defdelegate cleanup_staging(staging_key), to: LocalCAS
  defdelegate read(source, requested_bytes), to: LocalCAS
  defdelegate close(source), to: LocalCAS
  defdelegate verify(storage_key), to: LocalCAS
  defdelegate delete(storage_key), to: LocalCAS
  defdelegate capacity(), to: LocalCAS
end
```

- [ ] Define both opaque handles. The staged handle keeps ESS state/options private; the source handle owns only an fd and numeric bounds. Neither inspection can reveal a path, root, descriptor, or ESS struct:

```elixir
defmodule ForgeReleases.AssetStorage.StagedRef do
  @moduledoc false

  @enforce_keys [:inner, :options, :storage_key, :size]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            inner: ExStorageService.BlobStore.StagedBlob.t(),
            options: keyword(),
            storage_key: String.t(),
            size: non_neg_integer()
          }
end

defimpl Inspect, for: ForgeReleases.AssetStorage.StagedRef do
  def inspect(_staged, _options), do: "#ForgeReleases.AssetStorage.StagedRef<redacted>"
end
```

```elixir
defmodule ForgeReleases.AssetStorage.Source do
  @moduledoc false

  @enforce_keys [:io, :offset, :position, :remaining]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            io: :file.io_device(),
            offset: non_neg_integer(),
            position: non_neg_integer(),
            remaining: non_neg_integer()
          }
end

defimpl Inspect, for: ForgeReleases.AssetStorage.Source do
  def inspect(_source, _options), do: "#ForgeReleases.AssetStorage.Source<redacted>"
end
```

- [ ] Extend `FileSystem` with only the two non-recursive directory operations needed by survivor recovery:

```elixir
def ls(path), do: File.ls(path)
def rmdir(path), do: File.rmdir(path)
```

- [ ] Expand `LocalCAS` with the behavior, aliases, fd record, validators, readiness gate, and adapter-owned options. Retain the preflight code from Task 4:

```elixir
@behaviour ForgeReleases.AssetStorage

require Record
Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

alias ExStorageService.BlobStore.LocalCAS, as: ESSLocalCAS
alias ForgeReleases.AssetStorage.{Config, FileSystem, Manager, Source, StagedRef}

@digest_regex ~r/\A[0-9a-f]{64}\z/
@staging_key_regex ~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/
@maximum_read_bytes 1_048_576
@stage_option_keys [:max_size, :read_options]

defp ready_config do
  case Manager.status() do
    :ready ->
      try do
        {:ok, Config.load!()}
      rescue
        _error -> {:error, :unavailable}
      end

    {:not_ready, _reason} ->
      {:error, :unavailable}
  end
end

@impl true
def capacity, do: capacity(FileSystem)

@doc false
def capacity(fs) when is_atom(fs) do
  with {:ok, config} <- ready_config(),
       {:ok, cas} <- fs.filesystem_capacity(config.blob_root),
       {:ok, staging} <- fs.filesystem_capacity(config.tmp_root) do
    {:ok, %{cas: cas, staging: staging}}
  else
    _reason -> {:error, :unavailable}
  end
end

defp validate_digest(storage_key)
     when is_binary(storage_key) and storage_key =~ @digest_regex,
     do: :ok

defp validate_digest(_storage_key), do: {:error, :invalid_source}

defp validate_staging_key(key) when is_binary(key) and key =~ @staging_key_regex, do: :ok
defp validate_staging_key(_key), do: {:error, :invalid_source}

defp stage_options(%Config{} = config, staging_key, options) do
  with true <- Keyword.keyword?(options),
       true <- Enum.all?(Keyword.keys(options), &(&1 in @stage_option_keys)),
       read_options when is_list(read_options) <- Keyword.get(options, :read_options, []),
       :ok <- validate_read_options(read_options),
       max_size when is_integer(max_size) and max_size > 0 <-
         Keyword.get(options, :max_size, config.max_bytes),
       true <- max_size <= config.max_bytes do
    tmp_dir = Path.join([config.tmp_root, "uploads", staging_key])

    {:ok,
     config.context
     |> ExStorageService.Context.direct_blob_store_options()
     |> Keyword.merge(tmp_dir: tmp_dir, max_size: max_size), read_options}
  else
    _ -> {:error, :invalid_source}
  end
end

defp validate_read_options(options) do
  with true <- Keyword.keyword?(options),
       true <- Keyword.keys(options) |> Enum.sort() == [:length, :read_length, :read_timeout],
       length when is_integer(length) and length > 0 and length <= 1_048_576 <-
         Keyword.fetch!(options, :length),
       read_length when is_integer(read_length) and read_length > 0 and read_length <= length <-
         Keyword.fetch!(options, :read_length),
       timeout when is_integer(timeout) and timeout > 0 <- Keyword.fetch!(options, :read_timeout) do
    :ok
  else
    _ -> {:error, :invalid_source}
  end
end

defp blob_options(%Config{} = config) do
  config.context
  |> ExStorageService.Context.direct_blob_store_options()
end

defp recover_options(%Config{} = config, staging_key) do
  config.context
  |> ExStorageService.Context.direct_blob_store_options()
  |> Keyword.merge(
    tmp_dir: Path.join([config.tmp_root, "uploads", staging_key]),
    max_size: config.max_bytes
  )
end
```

- [ ] Implement reader staging, commit, discard, stat, verify, and delete. The successful tuples contain only domain metadata; the exact-pin comments stay at the affected production callsites:

```elixir
@impl true
def stage_from_reader(staging_key, reader, state, options)
    when is_function(reader, 2) and is_list(options) do
  with :ok <- validate_staging_key(staging_key),
       {:ok, config} <- ready_config(),
       {:ok, cas_options, read_options} <- stage_options(config, staging_key, options) do
    wrapped_reader = fn reader_state -> reader.(reader_state, read_options) end

    case ESSLocalCAS.stage_from_reader(wrapped_reader, state, cas_options) do
      {:ok, staged, final_state} ->
        ref = %StagedRef{
          inner: staged,
          options: cas_options,
          storage_key: staged.hash,
          size: staged.size
        }

        {:ok, ref, metadata(staged.hash, staged.size), final_state}

      {:error, reason, final_state} ->
        {:error, normalize(:stage, reason), final_state}
    end
  else
    {:error, reason} -> {:error, reason, state}
  end
end

def stage_from_reader(_staging_key, _reader, state, _options),
  do: {:error, :invalid_source, state}

@impl true
def commit(%StagedRef{} = staged) do
  with {:ok, _config} <- ready_config() do
    case ESSLocalCAS.commit(staged.inner, staged.options) do
      {:ok, ready}
      when ready.hash == staged.storage_key and ready.size == staged.size ->
        {:ok, metadata(staged.storage_key, staged.size)}

      {:ok, _mismatch} ->
        {:error, :integrity_mismatch}

      {:error, reason} ->
        {:error, normalize(:commit, reason)}
    end
  end
end

def commit(_staged), do: {:error, :invalid_source}

@impl true
def discard(%StagedRef{} = staged) do
  with {:ok, _config} <- ready_config() do
    case ESSLocalCAS.discard(staged.inner, staged.options) do
      :ok -> :ok
      {:error, reason} -> {:error, normalize(:discard, reason)}
    end
  end
end

def discard(_staged), do: {:error, :invalid_source}

@impl true
def stat(storage_key) do
  with :ok <- validate_digest(storage_key),
       {:ok, config} <- ready_config() do
    case ESSLocalCAS.stat(storage_key, blob_options(config)) do
      {:ok, %{hash: ^storage_key, size: size}} ->
        {:ok, %{storage_key: storage_key, size: size}}

      {:ok, _mismatch} ->
        {:error, :integrity_mismatch}

      {:error, reason} ->
        {:error, normalize(:stat, reason)}
    end
  end
end

@impl true
def verify(storage_key) do
  with :ok <- validate_digest(storage_key),
       {:ok, config} <- ready_config() do
    case ESSLocalCAS.verify(storage_key, blob_options(config)) do
      :ok -> :ok
      {:error, reason} -> {:error, normalize(:verify, reason)}
    end
  end
end

@impl true
def delete(storage_key) do
  with :ok <- validate_digest(storage_key),
       {:ok, config} <- ready_config() do
    case ESSLocalCAS.delete(storage_key, blob_options(config)) do
      :ok -> :ok
      {:error, reason} -> {:error, normalize(:delete, reason)}
    end
  end
end

defp metadata(storage_key, size) do
  %{sha256_digest: storage_key, storage_key: storage_key, size: size}
end
```

- [ ] Implement fd-based open/read/close. Resolve only the loose source, open it before returning, validate the live inode with `:file.read_file_info/1`, apply range bounds locally, clamp every read to 1 MiB, and treat a second close as success:

```elixir
@impl true
def open(storage_key, expected_size, range)
    when is_integer(expected_size) and expected_size >= 0 do
  with :ok <- validate_digest(storage_key),
       {:ok, config} <- ready_config(),
       {:ok, {:file, path, 0, ^expected_size}} <-
         ESSLocalCAS.open(storage_key, nil, blob_options(config)),
       {:ok, io} <- FileSystem.open(path, [:read, :raw, :binary]) do
    finish_open(io, expected_size, range)
  else
    {:ok, {:file, _path, _offset, _actual_size}} -> {:error, :integrity_mismatch}
    {:error, reason} -> {:error, normalize(:open, reason)}
    _other -> {:error, :integrity_mismatch}
  end
end

def open(_storage_key, _expected_size, _range), do: {:error, :invalid_source}

defp finish_open(io, expected_size, range) do
  result =
    with {:ok, info} <- FileSystem.read_file_info(io),
         :regular <- file_info(info, :type),
         ^expected_size <- file_info(info, :size),
         {:ok, offset, length} <- apply_range(expected_size, range) do
      {:ok, %Source{io: io, offset: offset, position: 0, remaining: length}}
    else
      {:error, :invalid_range} -> {:error, :invalid_source}
      _ -> {:error, :integrity_mismatch}
    end

  case result do
    {:ok, _source} = success -> success
    {:error, _reason} = error ->
      _ = FileSystem.close(io)
      error
  end
end

defp apply_range(size, range) when range in [nil, :all], do: {:ok, 0, size}

defp apply_range(size, {offset, length})
     when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 and
            offset <= size and length <= size - offset,
     do: {:ok, offset, length}

defp apply_range(_size, _range), do: {:error, :invalid_range}

@impl true
def recover_stage(staging_key, expected_digest, expected_size)
    when is_integer(expected_size) and expected_size >= 0 do
  with :ok <- validate_staging_key(staging_key),
       :ok <- validate_digest(expected_digest),
       {:ok, config} <- ready_config(),
       :ok <- enforce_survivor_cap(expected_size, config.max_bytes),
       {:ok, path} <- locate_single_survivor(FileSystem, config, staging_key, expected_size),
       options = recover_options(config, staging_key),
       {:ok, staged} <-
         ESSLocalCAS.recover_stage(path, expected_digest, expected_size, options) do
    {:ok,
     %StagedRef{
       inner: staged,
       options: options,
       storage_key: expected_digest,
       size: expected_size
     }}
  else
    {:error, reason} -> {:error, normalize(:recover, reason)}
  end
end

def recover_stage(_staging_key, _expected_digest, _expected_size),
  do: {:error, :invalid_source}

defp locate_single_survivor(fs, config, staging_key, expected_size) do
  directory = Path.join([config.tmp_root, "uploads", staging_key])

  with {:ok, %File.Stat{type: :directory}} <- fs.lstat(directory),
       {:ok, [entry]} <- fs.ls(directory),
       path = Path.join(directory, entry),
       {:ok, %File.Stat{type: :regular, size: ^expected_size}} <- fs.lstat(path) do
    {:ok, path}
  else
    {:error, :enoent} -> {:error, :not_found}
    {:ok, []} -> {:error, :not_found}
    {:ok, %File.Stat{type: :regular}} -> {:error, :integrity_mismatch}
    {:ok, %File.Stat{}} -> {:error, :invalid_source}
    {:ok, _entries} -> {:error, :invalid_source}
    {:error, _reason} -> {:error, :unavailable}
  end
end

defp enforce_survivor_cap(size, maximum_size) when size <= maximum_size, do: :ok
defp enforce_survivor_cap(_size, _maximum_size), do: {:error, :entity_too_large}

@impl true
def cleanup_staging(staging_key) do
  with :ok <- validate_staging_key(staging_key),
       {:ok, config} <- ready_config() do
    directory = Path.join([config.tmp_root, "uploads", staging_key])

    cleanup_single_survivor(FileSystem, directory)
  end
end

defp cleanup_single_survivor(fs, directory) do
  case fs.lstat(directory) do
    {:error, :enoent} ->
      :ok

    {:ok, %File.Stat{type: :directory}} ->
      with {:ok, entries} <- fs.ls(directory),
           :ok <- remove_direct_entry(fs, directory, entries),
           :ok <- remove_empty_directory(fs, directory) do
        :ok
      else
        {:error, reason} when reason in [:invalid_source, :not_found] -> {:error, reason}
        {:error, _reason} -> {:error, :unavailable}
      end

    {:ok, %File.Stat{}} ->
      {:error, :invalid_source}

    {:error, _reason} ->
      {:error, :unavailable}
  end
end

defp remove_direct_entry(_fs, _directory, []), do: :ok

defp remove_direct_entry(fs, directory, [entry]) do
  path = Path.join(directory, entry)

  case fs.lstat(path) do
    {:ok, %File.Stat{type: :regular}} ->
      case fs.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:error, :enoent} ->
      :ok

    _other ->
      {:error, :invalid_source}
  end
end

defp remove_direct_entry(_fs, _directory, _entries), do: {:error, :invalid_source}

defp remove_empty_directory(fs, directory) do
  case fs.rmdir(directory) do
    :ok -> :ok
    {:error, :enoent} -> :ok
    {:error, :enotempty} -> {:error, :invalid_source}
    {:error, reason} -> {:error, reason}
  end
end

@impl true
def read(%Source{remaining: 0}, requested_bytes)
    when is_integer(requested_bytes) and requested_bytes > 0,
    do: :eof

def read(%Source{} = source, requested_bytes)
    when is_integer(requested_bytes) and requested_bytes > 0 do
  length = min(source.remaining, min(requested_bytes, @maximum_read_bytes))

  case FileSystem.pread(source.io, source.offset + source.position, length) do
    {:ok, bytes} when byte_size(bytes) == length ->
      {:ok, bytes,
       %{source | position: source.position + length, remaining: source.remaining - length}}

    {:ok, _short} ->
      {:error, :integrity_mismatch}

    :eof ->
      {:error, :integrity_mismatch}

    {:error, _reason} ->
      {:error, :unavailable}
  end
end

def read(_source, _requested_bytes), do: {:error, :invalid_source}

@impl true
def close(%Source{io: io}) do
  try do
    case FileSystem.close(io) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  catch
    :error, :badarg -> :ok
    :exit, _reason -> :ok
  end
end

def close(_source), do: :ok
```

- [ ] Add the exhaustive normalizer. No raw ESS, filesystem, exception text, or path may cross the module:

```elixir
@doc false
def normalize(_operation, :not_found), do: :not_found
def normalize(_operation, reason)
    when reason in [:entity_too_large, :invalid_source, :integrity_mismatch, :unavailable],
    do: reason

def normalize(:commit, {:directory_sync, _reason}), do: :ambiguous_commit
def normalize(:recover, reason)
    when reason in [:checksum_mismatch, :size_mismatch, :stage_changed],
    do: :integrity_mismatch

def normalize(:recover, {:verify, :unexpected_eof}), do: :integrity_mismatch

def normalize(:recover, reason)
    when reason in [:invalid_hash, :invalid_size, :invalid_stage_path, :not_regular_file],
    do: :invalid_source

def normalize(_operation, reason)
    when reason in [:checksum_mismatch, :unexpected_eof],
    do: :integrity_mismatch

def normalize(_operation, {phase, reason})
    when phase in [:commit, :verify] and
           reason in [:existing_blob_mismatch, :unexpected_eof],
    do: :integrity_mismatch

def normalize(_operation, reason)
    when reason in [:invalid_hash, :invalid_range, :invalid_max_size],
    do: :invalid_source

def normalize(:stage, {:invalid_reader_result, _result}), do: :invalid_source
def normalize(:stage, {:stage, :invalid_chunk}), do: :invalid_source
def normalize(:stage, {:reader, _reason}), do: :invalid_source
def normalize(_operation, _reason), do: :unavailable
```

- [ ] Add assertions that the normalizer maps representative raw errors and never returns them:

```elixir
test "raw ESS and filesystem errors collapse to the storage algebra" do
  assert LocalCAS.normalize(:stat, :not_found) == :not_found
  assert LocalCAS.normalize(:stage, :entity_too_large) == :entity_too_large
  assert LocalCAS.normalize(:commit, {:directory_sync, :eio}) == :ambiguous_commit
  assert LocalCAS.normalize(:recover, :stage_changed) == :integrity_mismatch
  assert LocalCAS.normalize(:recover, {:verify, :unexpected_eof}) == :integrity_mismatch
  assert LocalCAS.normalize(:recover, :not_regular_file) == :invalid_source
  assert LocalCAS.normalize(:commit, {:commit, :existing_blob_mismatch}) ==
           :integrity_mismatch
  assert LocalCAS.normalize(:verify, :checksum_mismatch) == :integrity_mismatch
  assert LocalCAS.normalize(:open, :invalid_range) == :invalid_source
  assert LocalCAS.normalize(:delete, {:delete, :eacces}) == :unavailable
end
```

- [ ] Format and run the adapter test three times. Confirm there are no leaked staging files after ordinary errors:

```bash
mix format apps/forge_releases/lib/forge_releases/asset_storage.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/staged_ref.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/source.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/file_system.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex \
  apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs
mix test apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs \
  --repeat-until-failure 3
test -z "$(find tmp/test/release-assets/tmp/uploads -type f -print -quit)"
```

Expected green result: all three runs report `0 failures`; the final command exits `0` with no file paths printed.

- [ ] Commit the opaque byte-store boundary:

```bash
git add apps/forge_releases/lib/forge_releases/asset_storage.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/staged_ref.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/source.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/file_system.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex \
  apps/forge_releases/test/forge_releases/asset_storage/local_cas_test.exs
git commit -m "feat(releases): add opaque LocalCAS byte store"
```

### Task 7: Lock the v0.6.4 contracts and prove release/container restart behavior

**Files:**

- Create: `apps/forge_releases/test/forge_releases/asset_storage/local_cas_contract_test.exs`
- Create: `scripts/release_asset_storage_smoke.sh`
- Modify: `.env.example`
- Modify: `Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `README.md`
- Modify: `.github/workflows/e2e.yml`
- Modify: `apps/fornacast_api/test/release_distribution_contract_test.exs`

- [ ] Add exact-pin contract tests for the three supported v0.6.4 seams. These tests deliberately call ESS directly only to characterize the pinned dependency; production code continues to call it only inside the adapter:

```elixir
defmodule ForgeReleases.AssetStorage.LocalCASContractTest do
  use ExUnit.Case, async: true

  alias ExStorageService.BlobStore.LocalCAS

  defmodule RecordingDeleteFS do
    def rm(path) do
      record(:rm)
      File.rm(path)
    end

    def open_directory(path) do
      record(:open_directory)
      :file.open(String.to_charlist(path), [:read, :raw, :directory])
    end

    def sync(io) do
      record(:sync)

      if Process.get(:fail_delete_sync_once, false) do
        Process.put(:fail_delete_sync_once, false)
        {:error, :injected}
      else
        :file.sync(io)
      end
    end

    def close(io) do
      record(:close)
      :file.close(io)
    end

    defp record(call),
      do: Process.put(:delete_fs_calls, [call | Process.get(:delete_fs_calls, [])])
  end

  setup do
    root = Path.join(System.tmp_dir!(), "ess-contract-#{System.unique_integer([:positive])}")
    tmp_dir = Path.join(root, "tmp")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, tmp_dir: tmp_dir}
  end

  test "abrupt staging death leaves at most one bounded regular survivor", context do
    parent = self()
    config = ForgeReleases.AssetStorage.Config.load!()

    options =
      config.context
      |> ExStorageService.Context.direct_blob_store_options()
      |> Keyword.merge(root: context.root, tmp_dir: context.tmp_dir, max_size: 16)

    {pid, monitor} =
      spawn_monitor(fn ->
        LocalCAS.stage_from_reader(
          fn state ->
            send(parent, {:reader_entered, self()})

            receive do
              {:continue, chunk} -> {:ok, chunk, state}
            end
          end,
          :reader_state,
          options
        )
      end)

    assert_receive {:reader_entered, ^pid}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    survivors = Path.wildcard(Path.join(context.tmp_dir, "*"))
    assert length(survivors) <= 1

    for survivor <- survivors do
      assert {:ok, %File.Stat{type: :regular, size: size}} = File.lstat(survivor)
      assert size <= 16
      assert Path.dirname(survivor) == context.tmp_dir
    end
  end

  test "direct options and recover_stage publish a caller-owned completed stage", context do
    config = ForgeReleases.AssetStorage.Config.load!()

    options =
      config.context
      |> ExStorageService.Context.direct_blob_store_options()
      |> Keyword.merge(root: context.root, tmp_dir: context.tmp_dir, max_size: 16)

    assert options[:pack_module] == nil
    refute Keyword.has_key?(options, :bucket)

    payload = "recovered-stage"
    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    assert {:ok, completed_stage} = LocalCAS.stage(payload, options)
    stage_path = completed_stage.path
    assert Path.dirname(stage_path) == context.tmp_dir
    assert {:ok, %File.Stat{type: :regular, size: 15}} = File.lstat(stage_path)

    assert {:ok, staged} = LocalCAS.recover_stage(stage_path, digest, byte_size(payload), options)
    assert {:ok, %{hash: ^digest, size: 15}} = LocalCAS.commit(staged, options)
    assert :ok = LocalCAS.verify(digest, options)
    refute File.exists?(stage_path)
  end

  test "delete syncs its directory and safely retries an ambiguous sync", context do
    payload = "durable-delete-contract"
    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    config = ForgeReleases.AssetStorage.Config.load!()

    options =
      config.context
      |> ExStorageService.Context.direct_blob_store_options()
      |> Keyword.merge(root: context.root, tmp_dir: context.tmp_dir)

    path = LocalCAS.blob_path(digest, options)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, payload)
    Process.put(:delete_fs_calls, [])
    Process.put(:fail_delete_sync_once, true)

    assert {:error, {:directory_sync, :injected}} =
             LocalCAS.delete(
               digest,
               Keyword.put(options, :fs_module, RecordingDeleteFS)
             )

    refute File.exists?(path)
    assert Process.get(:delete_fs_calls) |> Enum.reverse() ==
             [:rm, :open_directory, :sync, :close]

    Process.put(:delete_fs_calls, [])
    assert :ok =
             LocalCAS.delete(
               digest,
               Keyword.put(options, :fs_module, RecordingDeleteFS)
             )
    assert Process.delete(:delete_fs_calls) |> Enum.reverse() ==
             [:rm, :open_directory, :sync, :close]
    assert {:error, :not_found} = LocalCAS.stat(digest, options)
  end
end
```

The delete test proves that an error after unlink remains ambiguous, and that an idempotent retry syncs the directory before the domain may record `absent`. The later release-domain plan supplies the durable `deleting` row and retry loop; no absent-object deletion workaround belongs here.

- [ ] Run the exact-pin tests before touching deployment files:

```bash
mix test apps/forge_releases/test/forge_releases/asset_storage/local_cas_contract_test.exs
```

Expected green result against exact 0.6.4: `0 failures`; recovery returns a committable stage without copying, direct options disable packed/legacy lookup, and delete records directory open/sync/close on both the ambiguous attempt and its safe retry.

- [ ] Add the reusable production-release probe. It stores a deterministic blob in `write` mode and proves stat/verify/open/read/idempotent-close after restart in `verify` mode:

```sh
#!/bin/sh
set -eu

release_root=${1:?release root is required}
phase=${2:?phase must be write or verify}
release_bin="${release_root}/bin/fornacast"

case "$phase" in
  write)
    "$release_bin" rpc '
      payload = "fornacast-release-asset-restart-smoke"
      reader = fn :start, options ->
        true = options[:length] <= 262_144
        {:ok, payload, :done}
      end

      {:ok, staged, metadata, :done} =
        ForgeReleases.AssetStorage.stage_from_reader(
          "release-restart-smoke",
          reader,
          :start,
          read_options: [length: 262_144, read_length: 262_144, read_timeout: 1_000]
        )

      {:ok, ^metadata} = ForgeReleases.AssetStorage.commit(staged)
      :ok
    '
    ;;
  verify)
    "$release_bin" rpc '
      payload = "fornacast-release-asset-restart-smoke"
      digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      size = byte_size(payload)
      true = ForgeReleases.AssetStorage.Manager.ready?()
      {:ok, %{storage_key: ^digest, size: ^size}} = ForgeReleases.AssetStorage.stat(digest)
      :ok = ForgeReleases.AssetStorage.verify(digest)
      {:ok, source} = ForgeReleases.AssetStorage.open(digest, size, :all)
      {:ok, ^payload, source} = ForgeReleases.AssetStorage.read(source, 1_048_576)
      :eof = ForgeReleases.AssetStorage.read(source, 1)
      :ok = ForgeReleases.AssetStorage.close(source)
      :ok = ForgeReleases.AssetStorage.close(source)
    '
    ;;
  *)
    echo "phase must be write or verify" >&2
    exit 64
    ;;
esac
```

- [ ] Add deployment configuration and operator documentation with these exact values:

```dotenv
# .env.example
FORNACAST_RELEASE_ASSET_STORAGE_ROOT=/data/release-assets
FORNACAST_RELEASE_ASSET_MAX_BYTES=2147483648
FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS=86400
```

```dockerfile
# Dockerfile runtime ENV block
FORNACAST_RELEASE_ASSET_STORAGE_ROOT=/data/release-assets \
FORNACAST_RELEASE_ASSET_MAX_BYTES=2147483648 \
FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS=86400 \
```

Keep `coreutils` explicitly in the final image's runtime `apt-get install`
list; `AssetStorage.capacity/0` uses its POSIX `df` implementation rather than
assuming a slim base image happens to contain it.

Copy the probe into the runtime image without adding a shell dependency:

```dockerfile
COPY scripts scripts
COPY --from=build --chown=fornacast:fornacast \
  /app/scripts/release_asset_storage_smoke.sh \
  /app/bin/release_asset_storage_smoke
```

Add these entries to the Compose `app.environment` map; the existing `/data` volume remains the only volume:

```yaml
FORNACAST_RELEASE_ASSET_STORAGE_ROOT: /data/release-assets
FORNACAST_RELEASE_ASSET_MAX_BYTES: ${FORNACAST_RELEASE_ASSET_MAX_BYTES:-2147483648}
FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS: ${FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS:-86400}
```

Set `app.stop_grace_period: 45s`. This is strictly longer than the ESS child's
30-second shutdown bound, so a normal Compose stop cannot escalate to SIGKILL
before the BEAM finishes its bounded shutdown.

Add this operational text to `README.md` beside the existing backup section:

```markdown
Release-asset bytes use embedded LocalCAS under
`FORNACAST_RELEASE_ASSET_STORAGE_ROOT` (default `/data/release-assets` in the
container). The first release supports one Fornacast BEAM with exclusive use
of one volume. Keep the Erlang node name and this root stable, and use
stop-before-start upgrades; do not run rolling or concurrent writers against
the same root. No S3 listener or S3 credentials are used.

Treat the Ecto database, ConfigStore database, release-asset Concord directory,
CAS directory, and staging directory as one cold recovery set. Stop Fornacast,
back up or restore every member while it remains stopped, then restart. The
default `/data` volume contains all local members; PostgreSQL must be backed up
in the same stopped maintenance window.
```

- [ ] Extend `ReleaseDistributionContractTest` before changing E2E. Assert the release config, exact dependency, container root, no new exposed port, cold-backup text, and both restart phases:

```elixir
test "release assets ship core LocalCAS without an S3 listener" do
  dockerfile = File.read!(@dockerfile)
  compose = File.read!(@compose)
  env_example = File.read!(@env_example)
  readme = File.read!(@readme)
  e2e = File.read!(@e2e_workflow)

  assert dockerfile =~ "FORNACAST_RELEASE_ASSET_STORAGE_ROOT=/data/release-assets"
  assert dockerfile =~ "coreutils"
  assert compose =~ "FORNACAST_RELEASE_ASSET_STORAGE_ROOT: /data/release-assets"
  assert compose =~ "stop_grace_period: 45s"
  assert env_example =~ "FORNACAST_RELEASE_ASSET_MAX_BYTES=2147483648"
  assert readme =~ "one Fornacast BEAM with exclusive use of one volume"
  assert readme =~ "Treat the Ecto database, ConfigStore database"
  refute dockerfile =~ "EXPOSE 9000"
  refute compose =~ ~r/^\s+- ["']?9000/m
  assert e2e =~ "ex_storage_service-0.6.4"
  assert e2e =~ "release_asset_storage_smoke.sh release/fornacast write"
  assert e2e =~ "release_asset_storage_smoke.sh release/fornacast verify"
  assert e2e =~ "fornacast.localcas.owner"
  assert e2e =~ "docker stop --time 45"
  assert e2e =~ ~s({{.State.ExitCode}})
  assert e2e =~ ~s({{.State.OOMKilled}})
  assert e2e =~ ~s(docker start "$container")
  refute e2e =~ "docker restart"
  assert_order(e2e, "release/fornacast write", "release/fornacast verify")
  assert_order(e2e, "docker stop --time 45", ~s(docker start "$container"))
end

test "production validates and clamps release-asset limits" do
  {output, status} = read_runtime_storage_config("2147483649", "3600")
  assert status == 0
  assert output =~ "max=2147483648 grace=3600"

  {invalid_output, invalid_status} = read_runtime_storage_config("0", "3599")
  assert invalid_status != 0
  assert invalid_output =~ "FORNACAST_RELEASE_ASSET_MAX_BYTES must be a decimal integer >= 1"
end

defp read_runtime_storage_config(max_bytes, grace_seconds) do
  elixir = System.find_executable("elixir") || flunk("elixir executable not found")

  System.cmd(
    elixir,
    [
      "-e",
      """
      config = Config.Reader.read!(#{inspect(@runtime_config)}, env: :prod)
      values = Keyword.fetch!(config, :fornacast)
      IO.puts("max=\#{values[:release_asset_max_bytes]} grace=\#{values[:release_asset_gc_grace_seconds]}")
      """
    ],
    cd: @root,
    env: [
      {"RELEASE_COMMAND", "start"},
      {"FORNACAST_DATABASE_ADAPTER", "turso"},
      {"SECRET_KEY_BASE", String.duplicate("s", 64)},
      {"FORNACAST_BASE_URL", "http://localhost:4890"},
      {"FORNACAST_REPO_STORAGE_ROOT", "/tmp/fornacast-runtime-config-repos"},
      {"FORNACAST_SSH_HOST", "localhost"},
      {"FORNACAST_SSH_PORT", "2222"},
      {"FORNACAST_SSH_SYSTEM_DIR", "/tmp/fornacast-runtime-config-ssh"},
      {"FORNACAST_RELEASE_ASSET_STORAGE_ROOT", "/tmp/fornacast-runtime-assets"},
      {"FORNACAST_RELEASE_ASSET_MAX_BYTES", max_bytes},
      {"FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS", grace_seconds}
    ],
    stderr_to_stdout: true
  )
end
```

- [ ] Run the red source contract before updating the workflow and deployment files:

```bash
mix test apps/fornacast_api/test/release_distribution_contract_test.exs
```

Expected red result: missing LocalCAS env/docs, release inspection, and restart-smoke strings.

- [ ] In E2E `Prepare e2e environment`, create the storage root and export stable storage/node values:

```yaml
mkdir -p e2e-data/repos e2e-data/ssh e2e-data/release-assets e2e-work
echo "FORNACAST_RELEASE_ASSET_STORAGE_ROOT=${GITHUB_WORKSPACE}/e2e-data/release-assets" >> "$GITHUB_ENV"
echo "RELEASE_DISTRIBUTION=name" >> "$GITHUB_ENV"
echo "RELEASE_NODE=fornacast_e2e@127.0.0.1" >> "$GITHUB_ENV"
```

After the first health check, inspect the release and write the restart marker:

```yaml
- name: Inspect embedded LocalCAS release
  run: |
    test -d release/fornacast/lib/ex_storage_service-0.6.4
    ! compgen -G 'release/fornacast/lib/ex_storage_service_s3-*'
    release/fornacast/bin/fornacast rpc '
      true = ForgeReleases.AssetStorage.Manager.ready?()
      nil = Application.spec(:ex_storage_service_s3)
      instance = GenServer.whereis(ExStorageService.Names.instance_supervisor(:fornacast_release_assets))
      [{_, engine, :worker, [ExStorageService.Storage.Engine]}] = Supervisor.which_children(instance)
      true = is_pid(engine)
    '
    sh scripts/release_asset_storage_smoke.sh release/fornacast write
    ! ss -ltn | grep -Eq ':(9000|9100)[[:space:]]'
```

After the existing Git/web checks, stop and restart the same release with the same node identity and root, then verify the descriptor path through the adapter:

```yaml
- name: Restart release with persisted LocalCAS bytes
  run: |
    old_pid="$(cat fornacast.pid)"
    timeout 45 release/fornacast/bin/fornacast stop
    wait "$old_pid"
    release/fornacast/bin/fornacast start > fornacast-restart.log 2>&1 &
    echo "$!" > fornacast.pid

    for attempt in $(seq 1 60); do
      if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null && \
         release/fornacast/bin/fornacast rpc 'ForgeReleases.AssetStorage.Manager.ready?()' | grep true; then
        break
      fi
      if [ "$attempt" = 60 ]; then
        cat fornacast-restart.log
        exit 1
      fi
      sleep 2
    done

    sh scripts/release_asset_storage_smoke.sh release/fornacast verify
    git -C e2e-work/demo ls-remote origin refs/heads/main
```

Add `fornacast-restart.log` to the failure artifact.

- [ ] Add a PR-only Docker boot/restart step after the release restart. It uses per-run labeled resources and the same container identity, publishes no ports, and removes resources only after verifying their random ownership label:

```yaml
- name: Docker LocalCAS boot and restart smoke
  if: github.event_name == 'pull_request'
  run: |
    owner="$(openssl rand -hex 16)"
    container="fornacast-localcas-smoke-${owner:0:12}"
    volume="fornacast-localcas-smoke-data-${owner:0:12}"
    cleanup() {
      status=$?
      trap - EXIT
      if [ "$(docker container inspect -f '{{ index .Config.Labels "fornacast.localcas.owner" }}' "$container" 2>/dev/null || true)" = "$owner" ]; then
        docker rm -f "$container" >/dev/null 2>&1 || true
      fi
      if [ "$(docker volume inspect -f '{{ index .Labels "fornacast.localcas.owner" }}' "$volume" 2>/dev/null || true)" = "$owner" ]; then
        docker volume rm "$volume" >/dev/null 2>&1 || true
      fi
      exit "$status"
    }
    trap cleanup EXIT
    ! docker container inspect "$container" >/dev/null 2>&1
    ! docker volume inspect "$volume" >/dev/null 2>&1
    docker build -t fornacast-localcas-smoke .
    docker volume create --label "fornacast.localcas.owner=$owner" "$volume"
    test "$(docker volume inspect -f '{{ index .Labels "fornacast.localcas.owner" }}' "$volume")" = "$owner"
    docker run -d --name "$container" \
      --label "fornacast.localcas.owner=$owner" \
      -e SECRET_KEY_BASE="$(openssl rand -hex 32)" \
      -e FORNACAST_BASE_URL=http://127.0.0.1:4890 \
      -v "$volume:/data" \
      fornacast-localcas-smoke
    test "$(docker container inspect -f '{{ index .Config.Labels "fornacast.localcas.owner" }}' "$container")" = "$owner"

    for attempt in $(seq 1 60); do
      if docker exec "$container" \
           /app/bin/fornacast rpc 'ForgeReleases.AssetStorage.Manager.ready?()' | grep true; then
        break
      fi
      if [ "$attempt" = 60 ]; then
        docker logs "$container"
        exit 1
      fi
      sleep 2
    done

    docker exec "$container" \
      /app/bin/release_asset_storage_smoke /app write
    docker stop --time 45 "$container"
    test "$(docker container inspect -f '{{.State.Running}}' "$container")" = false
    test "$(docker container inspect -f '{{.State.ExitCode}}' "$container")" = 0
    test "$(docker container inspect -f '{{.State.OOMKilled}}' "$container")" = false
    docker start "$container"

    for attempt in $(seq 1 60); do
      if docker exec "$container" \
           /app/bin/fornacast rpc 'ForgeReleases.AssetStorage.Manager.ready?()' | grep true; then
        break
      fi
      if [ "$attempt" = 60 ]; then
        docker logs "$container"
        exit 1
      fi
      sleep 2
    done

    docker exec "$container" \
      /app/bin/release_asset_storage_smoke /app verify
    test -z "$(docker port "$container")"
    docker exec "$container" \
      /app/bin/fornacast rpc 'nil = Application.spec(:ex_storage_service_s3)'
```

- [ ] Format, shell-check syntactically, and run every in-scope test:

```bash
chmod +x scripts/release_asset_storage_smoke.sh
sh -n scripts/release_asset_storage_smoke.sh
mix format --check-formatted
mix test apps/fornacast/test/operation_lease_test.exs \
  apps/forge_releases/test \
  apps/fornacast_web/test/fornacast_run_task_test.exs \
  apps/fornacast_api/test/release_distribution_contract_test.exs
```

Expected green result: shell syntax exits `0`, formatting exits `0`, and scoped ExUnit reports `0 failures`.

- [ ] Build and smoke the production release on the required toolchain:

```bash
elixir --version
rustc --version
MIX_ENV=prod mix deps.get --check-locked
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix release fornacast --overwrite

export RELEASE_COMMAND=start
export SECRET_KEY_BASE="$(openssl rand -hex 32)"
export FORNACAST_BASE_URL=http://127.0.0.1:4190
export FORNACAST_DATABASE_PATH="$PWD/tmp/localcas-release-smoke/fornacast.db"
export FORNACAST_CONFIG_DATABASE_PATH="$PWD/tmp/localcas-release-smoke/config.db"
export FORNACAST_REPO_STORAGE_ROOT="$PWD/tmp/localcas-release-smoke/repos"
export FORNACAST_SSH_HOST=127.0.0.1
export FORNACAST_SSH_BIND_IP=127.0.0.1
export FORNACAST_SSH_PORT=24222
export FORNACAST_SSH_SYSTEM_DIR="$PWD/tmp/localcas-release-smoke/ssh"
export FORNACAST_RELEASE_ASSET_STORAGE_ROOT="$PWD/tmp/localcas-release-smoke/assets"
export FORNACAST_API_BIND_IP=127.0.0.1
export FORNACAST_API_PORT=4191
export PORT=4190
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=fornacast_localcas_smoke@127.0.0.1

_build/prod/rel/fornacast/bin/fornacast daemon
for attempt in $(seq 1 60); do
  _build/prod/rel/fornacast/bin/fornacast rpc \
    'ForgeReleases.AssetStorage.Manager.ready?()' | grep true && break
  test "$attempt" != 60
  sleep 1
done
sh scripts/release_asset_storage_smoke.sh _build/prod/rel/fornacast write
timeout 45 _build/prod/rel/fornacast/bin/fornacast stop
_build/prod/rel/fornacast/bin/fornacast daemon
for attempt in $(seq 1 60); do
  _build/prod/rel/fornacast/bin/fornacast rpc \
    'ForgeReleases.AssetStorage.Manager.ready?()' | grep true && break
  test "$attempt" != 60
  sleep 1
done
sh scripts/release_asset_storage_smoke.sh _build/prod/rel/fornacast verify
timeout 45 _build/prod/rel/fornacast/bin/fornacast stop

test -d _build/prod/rel/fornacast/lib/ex_storage_service-0.6.4
! compgen -G '_build/prod/rel/fornacast/lib/ex_storage_service_s3-*'
```

Expected: Elixir reports `1.20.x`, Erlang/OTP reports `29`, Rust reports `1.96.x` or newer, compilation has no warnings, both smoke phases exit `0`, the second BEAM reads the first BEAM's blob, ESS core exists, and S3 is absent.

- [ ] Run the Docker acceptance locally or rely on the required E2E job result before merging:

```bash
owner="$(openssl rand -hex 16)"
container="fornacast-localcas-foundation-${owner:0:12}"
volume="fornacast-localcas-foundation-data-${owner:0:12}"
cleanup() {
  status=$?
  trap - EXIT
  if [ "$(docker container inspect -f '{{ index .Config.Labels "fornacast.localcas.owner" }}' "$container" 2>/dev/null || true)" = "$owner" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  if [ "$(docker volume inspect -f '{{ index .Labels "fornacast.localcas.owner" }}' "$volume" 2>/dev/null || true)" = "$owner" ]; then
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT
! docker container inspect "$container" >/dev/null 2>&1
! docker volume inspect "$volume" >/dev/null 2>&1
docker build -t fornacast-localcas-foundation .
docker volume create --label "fornacast.localcas.owner=$owner" "$volume"
test "$(docker volume inspect -f '{{ index .Labels "fornacast.localcas.owner" }}' "$volume")" = "$owner"
docker run -d --name "$container" \
  --label "fornacast.localcas.owner=$owner" \
  -e SECRET_KEY_BASE="$(openssl rand -hex 32)" \
  -e FORNACAST_BASE_URL=http://127.0.0.1:4890 \
  -v "$volume:/data" \
  fornacast-localcas-foundation
test "$(docker container inspect -f '{{ index .Config.Labels "fornacast.localcas.owner" }}' "$container")" = "$owner"
for attempt in $(seq 1 60); do
  docker exec "$container" \
    /app/bin/fornacast rpc 'ForgeReleases.AssetStorage.Manager.ready?()' | grep true && break
  test "$attempt" != 60
  sleep 1
done
docker exec "$container" \
  /app/bin/release_asset_storage_smoke /app write
docker stop --time 45 "$container"
test "$(docker container inspect -f '{{.State.Running}}' "$container")" = false
test "$(docker container inspect -f '{{.State.ExitCode}}' "$container")" = 0
test "$(docker container inspect -f '{{.State.OOMKilled}}' "$container")" = false
docker start "$container"
for attempt in $(seq 1 60); do
  docker exec "$container" \
    /app/bin/fornacast rpc 'ForgeReleases.AssetStorage.Manager.ready?()' | grep true && break
  test "$attempt" != 60
  sleep 1
done
docker exec "$container" \
  /app/bin/release_asset_storage_smoke /app verify
test -z "$(docker port "$container")"
```

Expected: the image boots, the graceful stop exits `0` without OOM or timeout
escalation, both probe phases exit `0` across start, and `docker port` prints
nothing. The exit trap removes only resources whose random ownership label
matches this invocation. Do not use a broad Docker prune.

- [ ] Commit the exact-pin and production acceptance work:

```bash
git add apps/forge_releases/test/forge_releases/asset_storage/local_cas_contract_test.exs \
  scripts/release_asset_storage_smoke.sh .env.example Dockerfile docker-compose.yml \
  README.md .github/workflows/e2e.yml \
  apps/fornacast_api/test/release_distribution_contract_test.exs
git commit -m "test(releases): prove LocalCAS release restart"
```

## Final review gate

- [ ] Confirm the diff contains foundation work only and no unrelated tracked or generated files:

```bash
git status --short
git diff --check
git diff --stat HEAD~7..HEAD
git diff --name-only HEAD~7..HEAD | sort
```

Expected: only files in the exact file map appear. No database files, release output, dependencies, node modules, native targets, credentials, or object paths are tracked.

- [ ] Scan the plan and implementation for incomplete markers and forbidden surface area:

```bash
! rg -n 'T[B]D|T[O]DO|implement lat[e]r|fill i[n]' \
  docs/superpowers/plans/2026-08-12-release-assets-localcas-foundation.md \
  apps/forge_releases
! rg -n 'ex_storage_service_s3|public_s3_enabled:\s*true|web_enabled:\s*true' \
  mix.exs apps/*/mix.exs config
! rg -n 'ForgeReleases\.(Release|BlobGC|Recovery)\b|defmodule ForgeReleases\.Asset\b|release_asset_operations|release_blobs' \
  apps/forge_releases/lib
! rg -n 'WORKAROUND\(upstream\): gsmlg-opt/ex_storage_service#(13|14|15)' \
  docs/superpowers/plans/2026-08-12-release-assets-localcas-foundation.md \
  apps/forge_releases
```

Expected: all four negative searches exit `0`; no temporary upstream workaround marker remains.

- [ ] Re-run type/surface consistency checks:

```bash
rg -U --multiline-dotall -n 'renew_owned\(.{0,600}now:.{0,200}lease_seconds:' \
  apps/fornacast/test/operation_lease_test.exs
rg -n 'def (stage_from_reader|commit|discard|stat|open|recover_stage|cleanup_staging|read|close|verify|delete|capacity)' \
  apps/forge_releases/lib/forge_releases/asset_storage.ex \
  apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex
! rg -n 'ExStorageService|:file\.io_device|path:' \
  apps/forge_releases/lib/forge_releases/asset_storage.ex
```

Expected: lease calls use the required keyword pair; facade and adapter expose the same twelve operations; the public contract contains no ESS type, fd type, or path field.

- [ ] Record fresh verification output in the implementation handoff: Turso and PostgreSQL lease results, scoped foundation results, exact lock result, Elixir/OTP/Rust versions, production release write/restart/verify, Docker write/graceful-stop/start/verify, absent S3 package, absent storage listener, and the final clean/known-dirty `git status`. Do not claim completion if PostgreSQL, release, or Docker evidence is missing.
