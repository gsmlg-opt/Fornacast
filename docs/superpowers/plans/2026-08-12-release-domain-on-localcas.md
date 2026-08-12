# Release Domain on LocalCAS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the complete `ForgeReleases` persistence and domain state machines on the already-proven embedded LocalCAS foundation, including retained Git tags, reader-driven uploads, descriptor-backed downloads, immediate logical deletion, crash recovery, digest-ledger fencing, delayed GC, bounded integrity auditing, and aggregate storage-pressure telemetry on both supported databases.

**Architecture:** SQL is the sole metadata, operation-journal, lease, and blob-inventory authority; LocalCAS stores only immutable bytes addressed by SHA-256. Foreground and recovery coordinators use portable compare-and-swap leases and a same-BEAM task fence around every potentially long filesystem or Git effect. User-visible deletion removes metadata immediately, while retained digest tombstones and reference-aware GC reclaim bytes later. This plan consumes the opaque `ForgeReleases.AssetStorage` contract from Plan 1 and does not expose storage paths or ESS values.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto 3.14, Turso/libSQL, PostgreSQL 17, GitCore/gix, ExStorageService 0.6.4 LocalCAS through Plan 1's adapter, ExUnit, and `:telemetry`.

---

## Dependencies and scope boundary

Execute this plan only after both prerequisites are present on the implementation branch:

1. `docs/superpowers/plans/2026-08-12-release-assets-localcas-foundation.md` is fully implemented, including `forge_releases` application wiring, the exact ESS 0.6.4 pin, readiness gating, opaque staging/source wrappers, `AssetStorage.open/3`, `recover_stage/3`, `cleanup_staging/1`, `read/2`, `close/1`, and path-free `capacity/0`, and owner-retaining `Fornacast.OperationLease.renew_owned/3` and `update_owned/4`.
2. The repository issues/pulls prerequisite work has landed, including `Fornacast.Audit.record_multi/8`, `ForgeRepos.with_write_fence/3`, `ForgeRepos.RepositoryWriteReconcilers`, durable operation rows, and the shared operation-lease implementation. Do not copy files from `.trees/repository-issues-pulls` into this branch.

[ExStorageService v0.6.4](https://github.com/gsmlg-opt/ex_storage_service/releases/tag/v0.6.4)
closes upstream issues [#13](https://github.com/gsmlg-opt/ex_storage_service/issues/13), [#14](https://github.com/gsmlg-opt/ex_storage_service/issues/14), and [#15](https://github.com/gsmlg-opt/ex_storage_service/issues/15) through [PR #16](https://github.com/gsmlg-opt/ex_storage_service/pull/16). Plans 1 and 2 therefore use the supported recovery, direct-loose-CAS, and durable-delete contracts without temporary workaround markers.

This plan owns release, asset, operation, and blob-ledger persistence; release/tag lifecycle; upload/download/metadata/delete domain APIs; monitored effect fencing; total recovery; BlobGC; integrity telemetry; aggregate capacity/operation/blob-state telemetry; and focused Turso/PostgreSQL acceptance. It explicitly excludes HTTP controllers, serializers, routes, OpenAPI files, client scripts, health endpoint changes, production releases, Docker acceptance, S3, and Git LFS. Those product/API and deployment checks belong to Plan 3.

## Public domain contract

Keep concrete upload, download, task-fence, LocalCAS, file-descriptor, lease, and staging values opaque outside `forge_releases`:

```elixir
@opaque upload :: ForgeReleases.Upload.t()
@opaque download :: ForgeReleases.AssetDownload.t()
@type reader_state :: term()
@type reader_result(state) ::
        {:more, binary(), state}
        | {:ok, binary(), state}
        | {:done, state}
        | {:error, term(), state}
@type reader(state) :: (state, keyword() -> reader_result(state))

@type error_reason ::
        :not_found
        | :forbidden
        | :already_exists
        | {:conflict, :tag_changed | :state_changed}
        | {:validation, [map()]}
        | {:payload_too_large, :asset}
        | {:request_timeout, :asset}
        | {:unavailable, atom()}

@spec list_releases(ForgeRepos.Repository.t(), map() | nil, keyword()) ::
        {:ok, Fornacast.Page.t(ForgeReleases.Release.t())} | {:error, error_reason()}
@spec latest_release(ForgeRepos.Repository.t(), map() | nil) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec get_release(ForgeRepos.Repository.t(), pos_integer(), map() | nil) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec get_release_by_tag(ForgeRepos.Repository.t(), String.t(), map() | nil) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec create_release(ForgeRepos.Repository.t(), map(), map(), map()) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec update_release(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map(), map(), map()) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec delete_release(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map(), map()) ::
        :ok | {:error, error_reason()}

@spec list_assets(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map() | nil, keyword()) ::
        {:ok, Fornacast.Page.t(ForgeReleases.Asset.t())} | {:error, error_reason()}
@spec get_asset(ForgeRepos.Repository.t(), pos_integer(), map() | nil) ::
        {:ok, ForgeReleases.Asset.t()} | {:error, error_reason()}
@spec begin_asset_upload(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map(), map(), map()) ::
        {:ok, upload()} | {:error, error_reason()}
@spec stream_asset_upload(upload(), reader(state), state) ::
        {:ok, ForgeReleases.Asset.t(), state} | {:error, error_reason(), state}
        when state: term()
@spec abort_asset_upload(upload(), error_reason()) :: :ok | {:error, error_reason()}
@spec update_asset(ForgeRepos.Repository.t(), ForgeReleases.Asset.t(), map(), map(), map()) ::
        {:ok, ForgeReleases.Asset.t()} | {:error, error_reason()}
@spec delete_asset(ForgeRepos.Repository.t(), ForgeReleases.Asset.t(), map(), map()) ::
        :ok | {:error, error_reason()}
@spec open_asset(ForgeRepos.Repository.t(), ForgeReleases.Asset.t(), map() | nil) ::
        {:ok, download()} | {:error, error_reason()}
@spec asset_download_metadata(download()) ::
        %{size: non_neg_integer(), content_type: String.t(), disposition: String.t()}
@spec read_asset_chunk(download(), pos_integer()) ::
        {:ok, binary(), download()} | :eof | {:error, error_reason()}
@spec close_asset_download(download()) :: :ok
@spec record_download(ForgeRepos.Repository.t(), ForgeReleases.Asset.t()) ::
        :ok | {:error, error_reason()}
@spec reconcile_repository(ForgeRepos.Repository.t()) ::
        :ok | {:error, {:unavailable, atom()}}
```

The arity-two reader receives all three bounded options on every invocation:

```elixir
probe_bytes = max(remaining_bytes + 1, 1)
remaining_read_ms = Enum.min([remaining_idle_ms, remaining_total_ms, 30_000])

[
  length: min(1_048_576, probe_bytes),
  read_length: min(65_536, probe_bytes),
  read_timeout: remaining_read_ms
]
```

Reject any callback result whose bytes exceed the supplied `:length` before
applying the domain's `remaining_bytes` check; the extra probe byte distinguishes
exact-cap EOF from a one-byte overflow without allocating the configured limit.

`ForgeReleases` treats reader state as an opaque term and always returns its latest value. The domain never receives an Authorization header or token. The only storage success shapes used by this plan are:

```elixir
{:ok, staged_ref,
 %{sha256_digest: digest, storage_key: digest, size: size}, reader_state}

{:ok, %{sha256_digest: digest, storage_key: digest, size: size}}
```

Crash recovery additionally consumes Plan 1's opaque staging APIs:

```elixir
AssetStorage.recover_stage(staging_key, expected_digest, expected_size)
# => {:ok, opaque_staged_ref} | {:error, storage_error}

AssetStorage.cleanup_staging(staging_key)
# => :ok | {:error, storage_error}
```

Download sources are read and closed only with `AssetStorage.read/2` and
`close/1`; Plan 2 never derives, opens, lists, logs, or deletes a staging path
itself.

Operational telemetry consumes Plan 1's path-free capacity snapshot:

```elixir
AssetStorage.capacity()
# =>
{:ok,
 %{
   cas: %{
     bytes: %{total: non_neg_integer(), available: non_neg_integer()},
     inodes: %{total: non_neg_integer(), available: non_neg_integer()}
   },
   staging: %{
     bytes: %{total: non_neg_integer(), available: non_neg_integer()},
     inodes: %{total: non_neg_integer(), available: non_neg_integer()}
   }
 }}
```

No capacity result or telemetry event may contain a root, mount, path, ESS value, credential, digest, or raw storage error.

## Exact file map

Create:

- `apps/fornacast/priv/repo/migrations/20260812000100_create_release_domain.exs`
- `apps/forge_releases/lib/forge_releases.ex`
- `apps/forge_releases/lib/forge_releases/release.ex`
- `apps/forge_releases/lib/forge_releases/asset.ex`
- `apps/forge_releases/lib/forge_releases/release_operation.ex`
- `apps/forge_releases/lib/forge_releases/asset_operation.ex`
- `apps/forge_releases/lib/forge_releases/release_asset_blob.ex`
- `apps/forge_releases/lib/forge_releases/blob_inventory.ex`
- `apps/forge_releases/lib/forge_releases/upload.ex`
- `apps/forge_releases/lib/forge_releases/asset_download.ex`
- `apps/forge_releases/lib/forge_releases/task_fence.ex`
- `apps/forge_releases/lib/forge_releases/monitored_work.ex`
- `apps/forge_releases/lib/forge_releases/recovery.ex`
- `apps/forge_releases/lib/forge_releases/recovery_scheduler.ex`
- `apps/forge_releases/lib/forge_releases/recovery_supervisor.ex`
- `apps/forge_releases/lib/forge_releases/blob_gc.ex`
- `apps/forge_releases/lib/forge_releases/blob_gc_scheduler.ex`
- `apps/forge_releases/lib/forge_releases/integrity_audit.ex`
- `apps/forge_releases/lib/forge_releases/storage_telemetry.ex`
- `apps/forge_releases/lib/forge_releases/storage_telemetry_scheduler.ex`
- `apps/forge_releases/test/support/fixtures.ex`
- `apps/forge_releases/test/support/fault_asset_storage.ex`
- `apps/forge_releases/test/release_domain_migration_test.exs`
- `apps/forge_releases/test/forge_releases_test.exs`
- `apps/forge_releases/test/blob_inventory_test.exs`
- `apps/forge_releases/test/task_fence_test.exs`
- `apps/forge_releases/test/asset_upload_test.exs`
- `apps/forge_releases/test/asset_download_test.exs`
- `apps/forge_releases/test/deletion_test.exs`
- `apps/forge_releases/test/recovery_test.exs`
- `apps/forge_releases/test/blob_gc_test.exs`
- `apps/forge_releases/test/integrity_audit_test.exs`
- `apps/forge_releases/test/storage_telemetry_test.exs`

Modify:

- `apps/forge_releases/mix.exs`
- `apps/forge_releases/lib/forge_releases/application.ex`
- `apps/forge_releases/test/forge_releases/application_test.exs`
- `apps/forge_releases/test/test_helper.exs`
- `config/config.exs`

Do not modify any `fornacast_api` source/test/OpenAPI file, root client script, production release configuration, Docker file, Compose file, or deployment workflow in this plan.

### Task 0: Enforce the two implementation prerequisites

**Files:**

- Verify: `docs/superpowers/plans/2026-08-12-release-assets-localcas-foundation.md`
- Verify: `apps/fornacast/lib/fornacast/operation_lease.ex`
- Verify: `apps/fornacast/lib/fornacast/audit.ex`
- Verify: `apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex`
- Verify: `apps/forge_releases/lib/forge_releases/asset_storage.ex`
- Verify: `apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex`

- [ ] Run the hard prerequisite gate before creating a release-domain file:

```bash
test -f apps/forge_releases/lib/forge_releases/asset_storage.ex && \
test -f apps/forge_releases/lib/forge_releases/asset_storage/local_cas.ex && \
test -f apps/fornacast/lib/fornacast/operation_lease.ex && \
test -f apps/fornacast/lib/fornacast/audit.ex && \
test -f apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex && \
rg -n 'def (renew_owned|update_owned)' apps/fornacast/lib/fornacast/operation_lease.ex && \
rg -n 'def (stage_from_reader|commit|discard|stat|open|read|close|verify|delete|recover_stage|cleanup_staging|capacity)' \
  apps/forge_releases/lib/forge_releases/asset_storage.ex
```

Expected before either prerequisite lands: non-zero exit status. Stop; merge or rebase the approved prerequisite work first. Expected after both land: exit status `0`, matches for `renew_owned/3`, both `update_owned/3` and `update_owned/4`, and every listed opaque adapter operation. In particular, Plan 1 must provide `recover_stage(staging_key, expected_digest, expected_size)`, `cleanup_staging(staging_key)`, and `capacity/0`; Plan 2 must not derive their paths itself.

- [ ] Prove the prerequisite contracts are green without broadening scope:

```bash
mix test apps/fornacast/test/operation_lease_test.exs \
  apps/forge_releases/test/forge_releases/asset_storage
```

Expected: `0 failures`. Do not create a commit for this gate.

### Task 1: Create portable release, operation, and retained blob-ledger persistence

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260812000100_create_release_domain.exs`
- Create: `apps/forge_releases/lib/forge_releases/release.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset.ex`
- Create: `apps/forge_releases/lib/forge_releases/release_operation.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_operation.ex`
- Create: `apps/forge_releases/lib/forge_releases/release_asset_blob.ex`
- Create: `apps/forge_releases/test/release_domain_migration_test.exs`
- Create: `apps/forge_releases/test/forge_releases_test.exs`
- Modify: `apps/forge_releases/mix.exs`
- Modify: `apps/forge_releases/test/forge_releases/application_test.exs`
- Modify: `apps/forge_releases/test/test_helper.exs`

- [ ] Extend the Plan 1 app project with the domain's direct dependencies and compile test support only in tests:

```elixir
def project do
  [
    app: :forge_releases,
    version: "0.1.3",
    build_path: "../../_build",
    config_path: "../../config/config.exs",
    deps_path: "../../deps",
    lockfile: "../../mix.lock",
    elixir: "~> 1.20",
    elixirc_paths: elixirc_paths(Mix.env()),
    start_permanent: Mix.env() == :prod,
    deps: deps()
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_environment), do: ["lib"]

defp deps do
  [
    {:fornacast, in_umbrella: true},
    {:forge_accounts, in_umbrella: true},
    {:forge_repos, in_umbrella: true},
    {:git_core, in_umbrella: true},
    {:ecto, "~> 3.14"},
    {:ex_storage_service, "== 0.6.4"}
  ]
end
```

Retain Plan 1's exact ESS pin and existing explicit root release/development application lists. Add assertions to its application test:

```elixir
test "domain dependencies are direct and test support compiles only in tests" do
  dependencies = ForgeReleases.MixProject.project() |> Keyword.fetch!(:deps) |> Keyword.keys()

  for dependency <- [:fornacast, :forge_accounts, :forge_repos, :git_core, :ecto, :ex_storage_service] do
    assert dependency in dependencies
  end

  assert ForgeReleases.MixProject.project()[:elixirc_paths] == ["lib", "test/support"]
end
```

- [ ] Prove the new dependency edges compile without a cycle before adding schemas:

```bash
mix compile --warnings-as-errors
mix xref graph --format cycles --label compile
```

Expected: compilation succeeds without warnings and xref reports no compile-connected cycles.

- [ ] Add the fresh-Turso migration contract and schema invariant tests. Use a separate one-connection Turso repo and assert that operation rows survive metadata deletion while blob rows remain as tombstones:

```elixir
defmodule ForgeReleases.MigrationTestRepo do
  use Ecto.Repo, otp_app: :forge_releases, adapter: Ecto.Adapters.Turso
end

defmodule ForgeReleases.ReleaseDomainMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeReleases.MigrationTestRepo

  @migrations Path.expand("../../fornacast/priv/repo/migrations", __DIR__)
  @tag :tmp_dir
  test "fresh Turso creates all release tables and recovery indexes", %{tmp_dir: dir} do
    start_supervised!({MigrationTestRepo, database: Path.join(dir, "release-domain.db"), pool_size: 1})
    Ecto.Migrator.run(MigrationTestRepo, @migrations, :up, all: true)

    %{rows: rows} =
      SQL.query!(MigrationTestRepo, "select name from sqlite_master where type = 'table'", [])

    names = MapSet.new(rows, fn [name] -> name end)

    assert MapSet.subset?(
             MapSet.new(~w(releases release_assets release_operations release_asset_operations release_asset_blobs)),
             names
           )

    %{rows: indexes} =
      SQL.query!(
        MigrationTestRepo,
        "select name from sqlite_master where type = 'index' and name like 'release_%'",
        []
      )

    index_names = MapSet.new(indexes, fn [name] -> name end)
    assert "release_assets_storage_key_state_index" in index_names
    assert "release_asset_operations_recovery_index" in index_names
    assert "release_asset_operations_terminal_cleanup_index" in index_names
    assert "release_asset_blobs_state_gc_after_id_index" in index_names
  end
end
```

Add schema tests with exact transition rejection and lowercase digest enforcement:

```elixir
test "available assets require size digest and equal storage key" do
  changeset =
    Asset.create_changeset(%Asset{}, %{
      release_id: 1,
      uploader_user_id: 1,
      name: "build.tar.gz",
      content_type: "application/gzip",
      state: :available,
      size: 3,
      sha256_digest: String.duplicate("a", 64),
      storage_key: String.duplicate("b", 64)
    })

  refute changeset.valid?
  assert {"must equal sha256_digest", _} = changeset.errors[:storage_key]
end

test "blob tombstones accept absent but never an uppercase digest" do
  refute ReleaseAssetBlob.create_changeset(%ReleaseAssetBlob{}, %{
           sha256_digest: String.duplicate("A", 64),
           size: 3,
           state: :absent
         }).valid?
end
```

- [ ] Run the tests and confirm the migration and schemas are absent:

```bash
mix test apps/forge_releases/test/release_domain_migration_test.exs \
  apps/forge_releases/test/forge_releases_test.exs --max-cases 1
```

Expected red result: compile errors for `ForgeReleases.Release`, `Asset`, `ReleaseOperation`, `AssetOperation`, and `ReleaseAssetBlob`, followed by no test execution.

- [ ] Add one adapter-portable migration. Use inline checks for Turso table creation and `create_postgres_check/3` for PostgreSQL checks; do not use row locks, partial indexes, generated columns, or adapter-specific upsert SQL. The table bodies must contain these exact columns and foreign-key deletion policies:

```elixir
def up do
  create table(:releases) do
    add :repository_id, references(:repositories, on_delete: :delete_all), null: false
    add :creator_user_id, references(:users, on_delete: :nilify_all)
    add :tag_name, :string, null: false
    add :target_commitish, :string, null: false
    add :name, :string
    add :body, :text
    add :draft, :boolean, null: false, default: false
    add :prerelease, :boolean, null: false, default: false
    add :asset_count, :integer, null: false, default: 0
    add :state, :string, null: false
    add :published_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  create unique_index(:releases, [:repository_id, :tag_name])
  create index(:releases, [:repository_id, :state, :published_at, :id])

  create table(:release_assets) do
    add :release_id, references(:releases, on_delete: :delete_all), null: false
    add :uploader_user_id, references(:users, on_delete: :nilify_all)
    add :name, :string, null: false
    add :label, :string
    add :content_type, :string, null: false
    add :size, :bigint
    add :sha256_digest, :string
    add :storage_key, :string
    add :download_count, :bigint, null: false, default: 0
    add :state, :string, null: false
    timestamps(type: :utc_datetime)
  end

  create unique_index(:release_assets, [:release_id, :name])
  create index(:release_assets, [:release_id, :state, :id])
  create index(:release_assets, [:storage_key, :state], name: :release_assets_storage_key_state_index)

  create table(:release_operations) do
    add :release_id, references(:releases, on_delete: :nilify_all)
    add :release_record_id, :bigint, null: false
    add :repository_id, references(:repositories, on_delete: :delete_all), null: false
    add :actor_user_id, references(:users, on_delete: :nilify_all)
    add :kind, :string, null: false
    add :state, :string, null: false
    add :target_ref, :string
    add :expected_oid, :string
    add :proposed_oid, :string
    add :request_id, :string, null: false
    add :ip_address, :string
    add :user_agent, :string
    add :failure_reason, :string
    add :lease_owner, :string
    add :lease_expires_at, :utc_datetime
    add :lock_version, :integer, null: false, default: 0
    timestamps(type: :utc_datetime)
  end

  create index(:release_operations, [:repository_id, :state, :id], name: :release_operations_recovery_index)
  create index(:release_operations, [:lease_expires_at])

  create table(:release_asset_operations) do
    add :asset_id, references(:release_assets, on_delete: :nilify_all)
    add :asset_record_id, :bigint, null: false
    add :release_record_id, :bigint, null: false
    add :repository_id, references(:repositories, on_delete: :delete_all), null: false
    add :actor_user_id, references(:users, on_delete: :nilify_all)
    add :kind, :string, null: false
    add :state, :string, null: false
    add :staging_key, :string
    add :storage_key, :string
    add :sha256_digest, :string
    add :size, :bigint
    add :request_id, :string, null: false
    add :ip_address, :string
    add :user_agent, :string
    add :failure_reason, :string
    add :lease_owner, :string
    add :lease_expires_at, :utc_datetime
    add :lock_version, :integer, null: false, default: 0
    timestamps(type: :utc_datetime)
  end

  create index(:release_asset_operations, [:repository_id, :state, :id], name: :release_asset_operations_recovery_index)
  create index(:release_asset_operations, [:state, :id], name: :release_asset_operations_terminal_cleanup_index)
  create index(:release_asset_operations, [:sha256_digest, :state])
  create index(:release_asset_operations, [:lease_expires_at])

  create table(:release_asset_blobs) do
    add :sha256_digest, :string, null: false
    add :size, :bigint, null: false
    add :state, :string, null: false
    add :gc_after, :utc_datetime
    add :integrity_failure, :string
    add :lease_owner, :string
    add :lease_expires_at, :utc_datetime
    add :lock_version, :integer, null: false, default: 0
    timestamps(type: :utc_datetime)
  end

  create unique_index(:release_asset_blobs, [:sha256_digest])
  create index(:release_asset_blobs, [:state, :gc_after, :id], name: :release_asset_blobs_state_gc_after_id_index)
  create index(:release_asset_blobs, [:lease_expires_at])

  create_postgres_check(:release_assets, :release_assets_available_check,
    "state != 'available' or (size is not null and sha256_digest is not null and storage_key = sha256_digest)")
  create_postgres_check(:release_asset_blobs, :release_asset_blobs_digest_check,
    "sha256_digest ~ '^[0-9a-f]{64}$'")
  create_postgres_check(:release_asset_blobs, :release_asset_blobs_size_check, "size >= 0")
end

defp create_postgres_check(table, name, expression) do
  unless repo().__adapter__() == Ecto.Adapters.Turso do
    create constraint(table, name, check: expression)
  end
end
```

Add explicit state checks for every enum, non-negative checks for `asset_count`, `size`, `download_count`, and `lock_version`, digest/storage-key checks for both asset and operation rows, and the same expressions inline in the Turso `CREATE TABLE` forms. `down/0` drops child tables in reverse order.

- [ ] Implement strict schemas with integer cross-context IDs and string-backed enums. Only `Release` may declare the same-context `has_many :assets` association. Each operation exposes `lease_update_changeset/2` so `OperationLease` can validate owner-retaining transitions:

```elixir
defmodule ForgeReleases.ReleaseOperation do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:prepared, :tag_ready, :metadata_ready, :deleting, :assets_deleted, :metadata_deleted, :completed, :failed]
  @transitions %{
    prepared: [:tag_ready, :failed],
    tag_ready: [:metadata_ready],
    metadata_ready: [:completed],
    deleting: [:assets_deleted],
    assets_deleted: [:metadata_deleted],
    metadata_deleted: [:completed]
  }

  schema "release_operations" do
    field :release_id, :integer
    field :release_record_id, :integer
    field :repository_id, :integer
    field :actor_user_id, :integer
    field :kind, Ecto.Enum, values: [:publish, :delete]
    field :state, Ecto.Enum, values: @states
    field :target_ref, :string
    field :expected_oid, :string
    field :proposed_oid, :string
    field :request_id, :string
    field :ip_address, :string
    field :user_agent, :string
    field :failure_reason, :string
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  def lease_update_changeset(operation, updates) when is_list(updates) do
    fields = [:state, :failure_reason]

    if Keyword.keyword?(updates) and Enum.all?(Keyword.keys(updates), &(&1 in fields)) do
      operation
      |> cast(Map.new(updates), fields)
      |> validate_transition(operation.state)
      |> validate_length(:failure_reason, max: 512)
    else
      operation |> change() |> add_error(:base, "contains immutable fields")
    end
  end

  defp validate_transition(changeset, source) do
    case fetch_change(changeset, :state) do
      {:ok, target} when target in Map.get(@transitions, source, []) -> changeset
      {:ok, _target} -> add_error(changeset, :state, "is not a valid transition")
      :error -> changeset
    end
  end
end
```

Use the corresponding asset-operation transitions `staging -> staged -> metadata_ready -> completed`, `staging | staged | metadata_ready -> failed`, and `deleting -> deleted`; use blob states `absent | pending | ready | candidate | deleting | corrupt`. The blob lease changeset permits `deleting -> absent` only after a durable delete result and `absent -> corrupt` only for an owner-retaining maintenance integrity finding; it permits no transition out of `corrupt`. `staging_key` is a sanitized logical key, never a path. Retain it through terminal transition and permit clearing it only from a terminal state after cleanup succeeds. Do not normalize digest input: require it already matches lowercase `~r/\A[0-9a-f]{64}\z/`, require `storage_key == sha256_digest`, sanitize failure strings to 512 printable characters, and reject every other immutable-field change.

Publication operation creation requires `target_ref` matching `refs/tags/<validated tag_name>` and a lowercase 40- or 64-character `proposed_oid`; `expected_oid` is either null or the same OID shape. Release-delete operation creation requires all three ref fields to be null. Upload operation transitions require digest/key/size together at `staged`; delete operations never accept those upload-only fields.

- [ ] Migrate and run the focused persistence suite:

```bash
MIX_ENV=test mix ecto.migrate
mix format apps/fornacast/priv/repo/migrations/20260812000100_create_release_domain.exs \
  apps/forge_releases/lib/forge_releases/{release,asset,release_operation,asset_operation,release_asset_blob}.ex \
  apps/forge_releases/test/release_domain_migration_test.exs \
  apps/forge_releases/test/forge_releases_test.exs
mix test apps/forge_releases/test/release_domain_migration_test.exs \
  apps/forge_releases/test/forge_releases_test.exs --max-cases 1
```

Expected green result: `0 failures`; the fresh Turso database has all five tables and exact indexes, invalid transitions fail changeset validation, metadata deletion retains operation rows, and an `absent` blob row remains queryable.

- [ ] Commit persistence:

```bash
git add apps/fornacast/priv/repo/migrations/20260812000100_create_release_domain.exs \
  apps/forge_releases/mix.exs \
  apps/forge_releases/lib/forge_releases/{release,asset,release_operation,asset_operation,release_asset_blob}.ex \
  apps/forge_releases/test/forge_releases/application_test.exs \
  apps/forge_releases/test/release_domain_migration_test.exs \
  apps/forge_releases/test/forge_releases_test.exs \
  apps/forge_releases/test/test_helper.exs
git commit -m "feat(releases): add durable release and blob persistence"
```

### Task 2: Publish and manage releases while retaining authoritative Git tags

**Files:**

- Create: `apps/forge_releases/lib/forge_releases.ex`
- Modify: `apps/forge_releases/lib/forge_releases/release.ex`
- Modify: `apps/forge_releases/lib/forge_releases/release_operation.ex`
- Modify: `apps/forge_releases/test/forge_releases_test.exs`
- Modify: `config/config.exs`

- [ ] Add failing lifecycle tests for a missing tag, an existing tag, ref conflict, draft visibility, deterministic latest selection, metadata update, and tag-retaining deletion. The existing-tag case deliberately supplies a nonexistent target and still succeeds without resolving or moving the tag:

```elixir
test "an existing direct tag is authoritative", %{repo: repository, writer: writer} do
  existing_oid = insert_commit_and_tag!(repository, "v1.0.0")

  assert {:ok, release} =
           ForgeReleases.create_release(
             repository,
             %{tag_name: "v1.0.0", target_commitish: "refs/heads/does-not-exist", name: "One"},
             writer,
             safe_request("publish-existing")
           )

  assert release.target_commitish == "refs/heads/does-not-exist"
  assert {:ok, ^existing_oid} =
           GitCore.exact_ref(repository_path(repository), "refs/tags/v1.0.0")
end

test "deleting metadata retains the Git tag and durable operation", %{repo: repository, writer: writer} do
  release = create_release!(repository, writer, "v2.0.0")
  assert :ok = ForgeReleases.delete_release(repository, release, writer, safe_request("delete"))
  assert {:error, :not_found} = ForgeReleases.get_release(repository, release.id, writer)
  assert {:ok, _oid} = GitCore.exact_ref(repository_path(repository), "refs/tags/v2.0.0")

  operation = Repo.get_by!(ReleaseOperation, release_record_id: release.id, kind: :delete)
  assert operation.state == :completed
  assert operation.release_id == nil
end
```

Also assert writer/admin-only mutation; private-repository authorization collapsing to `:not_found`; unique repository/tag; writer-only draft reads; publish-once `published_at`; only `name`, `body`, `draft`, and `prerelease` updates; latest excluding drafts/prereleases and ordering by `published_at DESC, id DESC`; and available assets preloaded once in ascending ID order.

- [ ] Run the focused lifecycle test and verify the context functions are absent:

```bash
mix test apps/forge_releases/test/forge_releases_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.create_release/4`, `update_release/5`, `delete_release/4`, and read functions.

- [ ] Implement authorization-first reads and retained-tag publication. Inspect the direct tag ref before resolving a target; only an absent tag resolves `target_commitish`. Run the decision and effect under the shared writer fence:

```elixir
defp publication_oids(path, target_ref, target_commitish, remaining_ms) do
  case GitCore.exact_ref(path, target_ref, deadline_ms: remaining_ms) do
    {:ok, nil} ->
      selector = %GitCore.RefSelector{kind: :legacy, full_name: target_commitish}

      case GitCore.resolve_snapshot(path, selector) do
        {:ok, snapshot} -> {:ok, nil, snapshot.oid}
        {:error, reason} -> normalize_git_error(reason)
      end

    {:ok, oid} ->
      {:ok, oid, oid}

    {:error, reason} ->
      normalize_git_error(reason)
  end
end

defp ensure_publication_ref(path, %{expected_oid: nil} = operation, remaining_ms) do
  case GitCore.compare_and_swap_ref(
         path,
         operation.target_ref,
         nil,
         operation.proposed_oid,
         :fast_forward,
         deadline_ms: remaining_ms
       ) do
    {:ok, oid} when oid == operation.proposed_oid ->
      retain_transition(operation, state: :tag_ready)

    {:ok, _other_oid} ->
      {:error, {:conflict, :tag_changed}}

    {:error, :conflict} -> classify_tag_conflict(path, operation, remaining_ms)
    {:error, reason} -> normalize_git_error(reason)
  end
end

defp ensure_publication_ref(path, operation, remaining_ms) do
  case GitCore.exact_ref(path, operation.target_ref, deadline_ms: remaining_ms) do
    {:ok, oid} when oid == operation.proposed_oid ->
      retain_transition(operation, state: :tag_ready)

    {:ok, _other_oid} ->
      {:error, {:conflict, :tag_changed}}

    {:error, reason} ->
      normalize_git_error(reason)
  end
end
```

Before this effect, insert one invisible `Release{state: :pending}` and one request-leased `ReleaseOperation{state: :prepared}` in a transaction. Existing tags store the same direct OID in `expected_oid` and `proposed_oid`; absent tags store `expected_oid: nil` and one resolved commit OID. Never re-resolve `target_commitish` after preparation.

- [ ] Implement owner-guarded visibility and update transactions with deduplicated audit. Publication makes metadata visible, records audit, and clears ownership together:

```elixir
defp finish_publication(release, operation, request_meta) do
  published_at = if release.draft, do: nil, else: DateTime.utc_now() |> DateTime.truncate(:second)

  Ecto.Multi.new()
  |> Ecto.Multi.update(
    :release,
    Release.publish_changeset(release, %{state: :available, published_at: published_at})
  )
  |> Ecto.Multi.run(:metadata_ready, fn _repo, _changes ->
    Fornacast.OperationLease.update_owned(
      ReleaseOperation,
      operation,
      [state: :metadata_ready],
      now: DateTime.utc_now() |> DateTime.truncate(:second),
      lease_seconds: 30
    )
  end)
  |> Fornacast.Audit.record_multi(
    :audit,
    audit_actor(operation.actor_user_id),
    "release.created",
    "release",
    fn %{release: visible} -> Integer.to_string(visible.id) end,
    %{repository_id: operation.repository_id, tag_name: release.tag_name},
    request_metadata: request_meta,
    operation_id: "release_operation:#{operation.id}"
  )
  |> Ecto.Multi.run(:operation, fn _repo, %{metadata_ready: retained} ->
    Fornacast.OperationLease.update_owned(ReleaseOperation, retained, state: :completed)
  end)
  |> Repo.transaction()
  |> case do
    {:ok, %{release: visible}} -> {:ok, preload_available_assets(visible)}
    {:error, _step, reason, _changes} -> normalize_domain_error(reason)
  end
end

defp audit_actor(nil), do: nil
defp audit_actor(id) when is_integer(id), do: %{id: id}
```

For `update_release/5`, use a state-qualified `update_all` in an `Ecto.Multi`, require one row, and record `release.updated` in that transaction. Draft-to-published sets `published_at` only when null. Never update `tag_name` or `target_commitish`.

- [ ] Implement logical release deletion as `deleting -> assets_deleted -> metadata_deleted -> completed`. Metadata hides at admission; the bounded loop invokes Task 6's asset deletion boundary and never deletes a Git ref:

```elixir
defp finish_release_deletion(repository, owned_operation, request_meta) do
  with {:ok, operation} <- delete_assets_in_batches(repository, owned_operation, 50),
       {:ok, operation} <- retain_transition(operation, state: :assets_deleted),
       {:ok, operation} <- delete_release_metadata(operation),
       {:ok, _operation} <- complete_release_delete(operation, request_meta) do
    :ok
  end
end

defp delete_release_metadata(operation) do
  Ecto.Multi.new()
  |> Ecto.Multi.delete_all(
    :release,
    from(release in Release,
      where: release.id == ^operation.release_record_id and release.state == :deleting
    )
  )
  |> Ecto.Multi.run(:operation, fn _repo, %{release: {count, _rows}} ->
    if count == 1 or is_nil(Repo.get(Release, operation.release_record_id)) do
      Fornacast.OperationLease.update_owned(
        ReleaseOperation,
        operation,
        [state: :metadata_deleted],
        now: utc_now(),
        lease_seconds: 30
      )
    else
      {:error, :state_changed}
    end
  end)
  |> Repo.transaction()
  |> unwrap_operation()
end
```

The final transaction records `release.deleted` with operation ID `release_operation:<id>` and calls releasing `OperationLease.update_owned/3`. The operation row retains `release_record_id` after `release_id` becomes null.

- [ ] Append release tag reconciliation after the already-landed Git-write and pull-merge entries:

```elixir
config :forge_repos,
  repository_write_reconcilers: [
    {100, :git_writes, ForgeRepos.GitWriteRecovery},
    {200, :pull_merges, ForgePulls.MergeRecovery},
    {300, :release_tags, ForgeReleases.Recovery}
  ]
```

Keep the exact first two entries found after the prerequisite merge; only append `{300, :release_tags, ForgeReleases.Recovery}`.

- [ ] Format, run, and commit the retained-tag lifecycle:

```bash
mix format apps/forge_releases/lib/forge_releases.ex \
  apps/forge_releases/lib/forge_releases/{release,release_operation}.ex \
  apps/forge_releases/test/forge_releases_test.exs config/config.exs
mix test apps/forge_releases/test/forge_releases_test.exs --max-cases 1 --seed 0
```

Expected green result: `0 failures`; existing tags never move, missing tags are created once, visibility rules hold, deletion retains the tag, and audit rows deduplicate.

```bash
git add apps/forge_releases/lib/forge_releases.ex \
  apps/forge_releases/lib/forge_releases/{release,release_operation}.ex \
  apps/forge_releases/test/forge_releases_test.exs config/config.exs
git commit -m "feat(releases): publish releases with retained tags"
```

### Task 3: Fence monitored filesystem work until the exact task is down

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/task_fence.ex`
- Create: `apps/forge_releases/lib/forge_releases/monitored_work.ex`
- Create: `apps/forge_releases/lib/forge_releases/recovery_supervisor.ex`
- Create: `apps/forge_releases/test/task_fence_test.exs`
- Modify: `apps/forge_releases/lib/forge_releases/application.ex`

- [ ] Add deterministic tests proving registration precedes work, renewal threads the newest capability, timeout kills the effect, lease loss prevents stale cleanup, and local recovery remains blocked until `:DOWN`:

```elixir
test "an expired operation stays fenced until its effect task is down", %{operation: row} do
  parent = self()

  coordinator =
    Task.async(fn ->
      MonitoredWork.run(AssetOperation, row, fn ->
        send(parent, {:effect_started, self()})
        receive do: (:finish -> :committed)
      end,
        task_supervisor: ForgeReleases.WorkTaskSupervisor,
        lease_seconds: 1,
        renew_after_ms: 5_000,
        timeout_ms: 10_000,
        now: fn -> frozen_now() end
      )
    end)

  assert_receive {:effect_started, effect_pid}
  assert TaskFence.active?({AssetOperation, row.id})
  assert :busy = claim_if_inactive(AssetOperation, row.id, "recovery", expired_now())

  Process.exit(effect_pid, :kill)
  assert {:error, :effect_down} = Task.await(coordinator)
  assert_eventually(fn -> refute TaskFence.active?({AssetOperation, row.id}) end)
  assert {:ok, _claimed} = claim_if_inactive(AssetOperation, row.id, "recovery", expired_now())
end

defp claim_if_inactive(module, id, owner, now) do
  if TaskFence.active?({module, id}),
    do: :busy,
    else: Fornacast.OperationLease.claim(module, id, owner, now, 30)
end
```

Add a second test that pauses beyond one renewal, reloads the row, and asserts both expiry and `lock_version` advanced; a third injects `{:error, :lost_lease}`, asserts the effect PID receives `:EXIT`, and asserts the stale coordinator performs no transition or staging cleanup. Pre-register the same fence key for a fourth test and kill a gated task before registration for a fifth; assert these return `{:error, :lost_lease}` and `{:error, :effect_down}` respectively, never raw `:already_active`/`:not_alive`, and perform no effect, transition, compensation, or staging cleanup. Send fake `{ref, result}`, `{:DOWN, ref, :process, pid, :normal}`, `{:EXIT, pid, :normal}`, and renewal messages with unrelated refs and assert they do not affect the active task.

- [ ] Run the focused test and confirm the fence modules are missing:

```bash
mix test apps/forge_releases/test/task_fence_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.TaskFence` and `ForgeReleases.MonitoredWork`.

- [ ] Implement a monitor-owned registry. Register only a live PID, reject duplicate keys, remove a key only for its correlated monitor reference, and expose no PID publicly:

```elixir
defmodule ForgeReleases.TaskFence do
  use GenServer

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(options, :name, __MODULE__))
  end

  def register(key, pid), do: GenServer.call(__MODULE__, {:register, key, pid})
  def active?(key), do: GenServer.call(__MODULE__, {:active?, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, key, pid}, _from, state) when is_pid(pid) do
    cond do
      Map.has_key?(state, key) ->
        {:reply, {:error, :already_active}, state}

      not Process.alive?(pid) ->
        {:reply, {:error, :not_alive}, state}

      true ->
        ref = Process.monitor(pid)
        {:reply, :ok, Map.put(state, key, {pid, ref})}
    end
  end

  def handle_call({:active?, key}, _from, state), do: {:reply, Map.has_key?(state, key), state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      Enum.reduce(state, state, fn
        {key, {^pid, ^ref}}, accumulator -> Map.delete(accumulator, key)
        _entry, accumulator -> accumulator
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
```

- [ ] Implement `MonitoredWork.run/4` with an immediate owner-retaining renewal followed by a gated linked task. The effect cannot begin before both renewal and successful fence registration. Keep one absolute timeout deadline while resetting only the renewal timer. Use this exact result algebra: `{:ok, value, newest_row}` for effect success; `{:error, reason, newest_row}` when the effect returns an error; and `{:error, :lost_lease | :timeout | :effect_down}` when ownership is unavailable.

```elixir
defmodule ForgeReleases.MonitoredWork do
  alias ForgeReleases.TaskFence
  alias Fornacast.OperationLease

  def run(module, owned_row, effect, options) when is_function(effect, 0) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      run_trapping_exits(module, owned_row, effect, options)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp run_trapping_exits(module, owned_row, effect, options) do
    supervisor = Keyword.fetch!(options, :task_supervisor)
    lease_seconds = Keyword.fetch!(options, :lease_seconds)
    renew_after_ms = Keyword.fetch!(options, :renew_after_ms)
    timeout_ms = Keyword.fetch!(options, :timeout_ms)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)

    case OperationLease.renew_owned(module, owned_row,
           now: now.(),
           lease_seconds: lease_seconds
         ) do
      {:ok, renewed} ->
        start_registered_task(
          module,
          renewed,
          effect,
          supervisor,
          now,
          lease_seconds,
          renew_after_ms,
          timeout_ms
        )

      {:error, :lost_lease} ->
        {:error, :lost_lease}
    end
  end

  defp start_registered_task(
         module,
         owned_row,
         effect,
         supervisor,
         now,
         lease_seconds,
         renew_after_ms,
         timeout_ms
       ) do
    coordinator = self()

    task =
      Task.Supervisor.async(supervisor, fn ->
        receive do
          {:run, ^coordinator} -> effect.()
        end
      end)

    case TaskFence.register({module, owned_row.id}, task.pid) do
      :ok ->
        send(task.pid, {:run, coordinator})
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        await(task, module, owned_row, supervisor, now, lease_seconds, renew_after_ms, deadline)

      {:error, :already_active} ->
        Task.Supervisor.terminate_child(supervisor, task.pid)
        await_termination(task, false, false)
        {:error, :lost_lease}

      {:error, :not_alive} ->
        await_termination(task, false, false)
        {:error, :effect_down}
    end
  end

  defp await(task, module, row, supervisor, now, lease_seconds, renew_ms, deadline) do
    renewal = Process.send_after(self(), {:renew, task.ref}, renew_ms)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, result} when ref == task.ref ->
        cancel_renewal(renewal, task.ref)
        await_termination(task, false, false)
        normalize_effect_result(result, row)

      {:DOWN, ref, :process, pid, _reason} when ref == task.ref and pid == task.pid ->
        cancel_renewal(renewal, task.ref)
        await_termination(task, true, false)
        {:error, :effect_down}

      {:EXIT, pid, _reason} when pid == task.pid ->
        cancel_renewal(renewal, task.ref)
        await_termination(task, false, true)
        {:error, :effect_down}

      {:renew, ref} when ref == task.ref ->
        case OperationLease.renew_owned(module, row, now: now.(), lease_seconds: lease_seconds) do
          {:ok, renewed} ->
            await(task, module, renewed, supervisor, now, lease_seconds, renew_ms, deadline)

          {:error, :lost_lease} ->
            terminate_and_wait(supervisor, task, {:error, :lost_lease})
        end
    after
      remaining ->
        cancel_renewal(renewal, task.ref)
        terminate_and_wait(supervisor, task, {:error, :timeout})
    end
  end

  defp terminate_and_wait(supervisor, task, result) do
    Task.Supervisor.terminate_child(supervisor, task.pid)
    await_termination(task, false, false)
    result
  end

  defp await_termination(_task, true, true), do: :ok

  defp await_termination(task, saw_down, saw_exit) do
    receive do
      {:DOWN, ref, :process, pid, _reason} when ref == task.ref and pid == task.pid ->
        await_termination(task, true, saw_exit)

      {:EXIT, pid, _reason} when pid == task.pid ->
        await_termination(task, saw_down, true)
    after
      5_000 -> exit({:task_down_timeout, task.ref})
    end
  end

  defp normalize_effect_result({:ok, value}, row), do: {:ok, value, row}
  defp normalize_effect_result({:error, reason}, row), do: {:error, reason, row}
  defp normalize_effect_result(value, row), do: {:ok, value, row}

  defp cancel_renewal(timer, ref) do
    if Process.cancel_timer(timer, async: false, info: false) == false do
      receive do
        {:renew, ^ref} -> :ok
      after
        0 -> :ok
      end
    end
  end
end
```

Ignore messages whose refs/PIDs do not match the current task. The coordinator temporarily traps exits so a deliberately killed effect cannot kill the caller, correlates and consumes both the exact `:DOWN` and exact `:EXIT`, and restores the caller's prior `trap_exit` flag only after both signals arrive. Add tests for prior flag values `true` and `false` and assert restoration. Do not unlink the effect: coordinator death must still kill it, and `TaskFence` must observe `:DOWN`. `TaskFence` implementation errors remain private: duplicate registration normalizes to `:lost_lease`, and a dead gated task normalizes to `:effect_down`. Every caller must exhaustively distinguish a three-tuple effect error, which carries the only row safe to mutate, from no-row `:lost_lease`, `:timeout`, and `:effect_down`. A no-row result returns unavailable without discarding staging, releasing a lease, compensating metadata/quota, deleting bytes, or marking corruption with the stale input struct.

- [ ] Supervise the work task supervisor and fence under `:one_for_all`, with schedulers appended after the fence in Tasks 7 and 8. Keep Plan 1's storage supervisor as its existing sibling:

```elixir
defmodule ForgeReleases.RecoverySupervisor do
  use Supervisor

  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(_options) do
    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: ForgeReleases.WorkTaskSupervisor},
        id: ForgeReleases.WorkTaskSupervisor
      ),
      ForgeReleases.TaskFence
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
```

Add `ForgeReleases.RecoverySupervisor` after `ForgeReleases.AssetStorage.Supervisor` in `ForgeReleases.Application`. A fence crash must terminate the task supervisor before the subtree restarts.

- [ ] Run the race-focused test repeatedly and commit:

```bash
mix format apps/forge_releases/lib/forge_releases/{task_fence,monitored_work,recovery_supervisor,application}.ex \
  apps/forge_releases/test/task_fence_test.exs
for seed in 0 1 2 3 4; do
  mix test apps/forge_releases/test/task_fence_test.exs --max-cases 1 --seed "$seed" || exit 1
done
```

Expected: all five runs report `0 failures`; timeout and lease-loss cases observe `:DOWN` before a later claim succeeds.

```bash
git add apps/forge_releases/lib/forge_releases/{task_fence,monitored_work,recovery_supervisor,application}.ex \
  apps/forge_releases/test/task_fence_test.exs
git commit -m "feat(releases): fence monitored storage work"
```

### Task 4: Make the retained blob ledger arbitrate attachment and GC

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/blob_inventory.ex`
- Create: `apps/forge_releases/test/blob_inventory_test.exs`
- Modify: `apps/forge_releases/lib/forge_releases/release_asset_blob.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_operation.ex`

- [ ] Add serial Turso tests and real PostgreSQL race tests for every attachment transition and the two possible upload-versus-GC winners:

```elixir
test "every attachment touches the version including ready to ready", %{operation: operation} do
  digest = sha256("same bytes")
  blob = insert_blob!(digest, 10, :ready)

  assert {:ok, first_operation, first_blob} =
           BlobInventory.attach(operation, digest, 10, now: frozen_now(), lease_seconds: 30)

  assert first_operation.sha256_digest == digest
  assert first_blob.state == :ready
  assert first_blob.lock_version == blob.lock_version + 1

  operation_2 = insert_staging_operation!()
  assert {:ok, _second_operation, second_blob} =
           BlobInventory.attach(operation_2, digest, 10, now: frozen_now(), lease_seconds: 30)

  assert second_blob.lock_version == first_blob.lock_version + 1
end

test "candidate attachment becomes pending and invalidates an observed GC version", %{operation: operation} do
  digest = sha256("candidate")
  blob = insert_blob!(digest, 9, :candidate, gc_after: frozen_now())

  assert {:ok, _operation, attached} =
           BlobInventory.attach(operation, digest, 9, now: frozen_now(), lease_seconds: 30)

  assert attached.state == :pending
  assert attached.gc_after == nil
  assert :busy = BlobInventory.claim_deletion(blob.id, blob.lock_version, "gc", frozen_now(), 30)
end

test "a deletion lease blocks attachment even after SQL expiry", %{operation: operation} do
  digest = sha256("leased")
  insert_blob!(digest, 6, :deleting, lease_owner: "old-gc", lease_expires_at: expired_now())

  assert {:error, :busy_deleting} =
           BlobInventory.attach(operation, digest, 6, now: frozen_now(), lease_seconds: 30)
end
```

Also cover missing-row insertion as `pending`; `absent -> pending`; `pending -> pending`; size mismatch; `corrupt` fail-closed; unexpired lease rejection; expired non-ready lease rejection; state/version-qualified takeover of an expired `ready` open lease when its `TaskFence` is inactive; refusal to take over the same lease while its fence is active; asset and nonterminal-operation reachability; both concurrent outcomes where attachment invalidates the GC version or GC's single conditional claim wins and blocks attachment; and no mutable reference counter. In the expired-ready takeover case, assert the stale opener's later release loses its version and cannot clear the new owner's state.

- [ ] Run the focused suite and verify the inventory module is absent:

```bash
mix test apps/forge_releases/test/blob_inventory_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.BlobInventory`.

- [ ] Implement attachment in the same transaction that persists the operation digest. Insert a missing tombstone idempotently, reload its version, then conditionally touch exactly one unleased, same-sized, attachable row. Never promote `candidate` directly to ready:

```elixir
defmodule ForgeReleases.BlobInventory do
  import Ecto.Query

  alias ForgeReleases.{Asset, AssetOperation, ReleaseAssetBlob, TaskFence}
  alias Fornacast.{OperationLease, Repo}

  @asset_references [:pending, :available, :deleting]
  @operation_references [:staged, :metadata_ready]

  def attach(owned_operation, digest, size, options) do
    now = Keyword.fetch!(options, :now)
    lease_seconds = Keyword.fetch!(options, :lease_seconds)

    Repo.transaction(fn ->
      Repo.insert(
        ReleaseAssetBlob.create_changeset(%ReleaseAssetBlob{}, %{
          sha256_digest: digest,
          size: size,
          state: :pending
        }),
        on_conflict: :nothing,
        conflict_target: :sha256_digest
      )

      blob = Repo.get_by!(ReleaseAssetBlob, sha256_digest: digest)

      query =
        from item in ReleaseAssetBlob,
          where:
            item.id == ^blob.id and item.lock_version == ^blob.lock_version and
              item.size == ^size and is_nil(item.lease_owner) and
              item.state in [:absent, :pending, :ready, :candidate]

      target_state = if blob.state == :ready, do: :ready, else: :pending

      case Repo.update_all(query,
             set: [state: target_state, gc_after: nil, integrity_failure: nil],
             inc: [lock_version: 1]
           ) do
        {1, _rows} ->
          touched = Repo.get!(ReleaseAssetBlob, blob.id)

          case OperationLease.update_owned(
                 AssetOperation,
                 owned_operation,
                 [
                   state: :staged,
                   sha256_digest: digest,
                   storage_key: digest,
                   size: size
                 ],
                 now: now,
                 lease_seconds: lease_seconds
               ) do
            {:ok, operation} -> {operation, touched}
            {:error, reason} -> Repo.rollback(reason)
          end

        {0, _rows} ->
          Repo.rollback(classify_attachment_conflict(blob.id, digest, size))
      end
    end)
    |> case do
      {:ok, {operation, blob}} -> {:ok, operation, blob}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

`classify_attachment_conflict/3` reloads once for the public result only: size mismatch or `corrupt` returns `:integrity_mismatch`; `deleting`, a non-ready leased row, an unexpired owner, or an active local fence returns `:busy_deleting`; a changed version returns `:busy_deleting` for bounded retry. For exactly a `ready` row whose non-null lease has expired and whose `TaskFence` is inactive, call the observed-version helper below once, reload, and retry the whole attachment transaction. The transaction rolls back both the blob touch and operation transition on any failure.

```elixir
def reclaim_expired_ready(%ReleaseAssetBlob{} = observed, now) do
  if TaskFence.active?({ReleaseAssetBlob, observed.id}) do
    :busy
  else
    query =
      from blob in ReleaseAssetBlob,
        where:
          blob.id == ^observed.id and blob.lock_version == ^observed.lock_version and
            blob.state == :ready and not is_nil(blob.lease_owner) and
            blob.lease_expires_at <= ^now

    case Repo.update_all(query,
           set: [lease_owner: nil, lease_expires_at: nil],
           inc: [lock_version: 1]
         ) do
      {1, _rows} -> {:ok, Repo.get!(ReleaseAssetBlob, observed.id)}
      {0, _rows} -> :busy
    end
  end
end
```

This is the only generic stale-open cleanup primitive. It never clears `pending`, `candidate`, `deleting`, `absent`, or `corrupt` ownership. A slow request that outlives its lease is deliberately made stale by the version increment and must close/fail when it later tries to release.

- [ ] Implement indexed reachability and the candidate/deletion conditional claims. The deletion claim is one SQL update that compares the observed version and rechecks both reference sets inside the statement:

```elixir
def reachable?(digest) do
  Repo.exists?(
    from asset in Asset,
      where: asset.storage_key == ^digest and asset.state in ^@asset_references
  ) or
    Repo.exists?(
      from operation in AssetOperation,
        where:
          operation.sha256_digest == ^digest and operation.state in ^@operation_references
    )
end

def claim_deletion(id, observed_version, owner, now, lease_seconds) do
  expires_at = DateTime.add(now, lease_seconds, :second)

  asset_reference =
    from asset in Asset,
      where:
        asset.storage_key == parent_as(:blob).sha256_digest and
          asset.state in ^@asset_references,
      select: 1

  operation_reference =
    from operation in AssetOperation,
      where:
        operation.sha256_digest == parent_as(:blob).sha256_digest and
          operation.state in ^@operation_references,
      select: 1

  query =
    from blob in ReleaseAssetBlob,
      as: :blob,
      where:
        blob.id == ^id and blob.lock_version == ^observed_version and
          blob.state == :candidate and blob.gc_after <= ^now and
          is_nil(blob.lease_owner) and not exists(subquery(asset_reference)) and
          not exists(subquery(operation_reference))

  case Repo.update_all(query,
         set: [state: :deleting, lease_owner: owner, lease_expires_at: expires_at],
         inc: [lock_version: 1]
       ) do
    {1, _rows} -> {:ok, Repo.get!(ReleaseAssetBlob, id)}
    {0, _rows} -> :busy
  end
end

def claim_deleting(%ReleaseAssetBlob{state: :deleting} = observed, owner, now, lease_seconds) do
  expires_at = DateTime.add(now, lease_seconds, :second)

  query =
    ReleaseAssetBlob
    |> from(as: :blob)
    |> where(
      [blob],
      blob.id == ^observed.id and blob.lock_version == ^observed.lock_version and
        blob.state == :deleting and
        (is_nil(blob.lease_owner) or blob.lease_expires_at <= ^now) and
        not exists(subquery(asset_reference_query())) and
        not exists(subquery(operation_reference_query()))
    )

  case Repo.update_all(query,
         set: [lease_owner: owner, lease_expires_at: expires_at],
         inc: [lock_version: 1]
       ) do
    {1, _rows} -> {:ok, Repo.get!(ReleaseAssetBlob, observed.id)}
    {0, _rows} -> :busy
  end
end
```

Extract `asset_reference_query/0` and `operation_reference_query/0` from the first claim so both claims use the identical SQL reachability predicates. Call `claim_deleting/4` only after `TaskFence.active?({ReleaseAssetBlob, observed.id})` is false. Add a parallel conditional `mark_candidate/2` for unreferenced `ready` or orphaned `pending` rows: `mark_candidate(%ReleaseAssetBlob{} = observed, %DateTime{} = gc_after)`. It compares the struct's `lock_version`, requires no lease, rechecks both `NOT EXISTS` subqueries, sets `state: :candidate`, sets `gc_after`, and increments `lock_version`. `ready_blob/3` conditionally moves `pending -> ready` only after adapter commit/stat confirmation; it may leave `ready` as ready while touching the version. `mark_corrupt/3` accepts only a sanitized failure class and never repairs bytes.

- [ ] Run the portable suite, then the PostgreSQL race cases, and commit:

```bash
mix format apps/forge_releases/lib/forge_releases/{blob_inventory,release_asset_blob,asset_operation}.ex \
  apps/forge_releases/test/blob_inventory_test.exs
mix test apps/forge_releases/test/blob_inventory_test.exs --max-cases 1 --seed 0
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test \
  mix test apps/forge_releases/test/blob_inventory_test.exs --max-cases 1 --seed 0
```

Expected green result for each adapter: `0 failures`; each race has exactly one winner, ready-to-ready attachment increments the version, and attachment never overlaps an unexpired, non-ready, or locally fenced lease. An expired unfenced `ready` lease is reclaimed by exact state/version CAS before attachment proceeds, and its stale prior owner cannot release the new version.

```bash
git add apps/forge_releases/lib/forge_releases/{blob_inventory,release_asset_blob,asset_operation}.ex \
  apps/forge_releases/test/blob_inventory_test.exs
git commit -m "feat(releases): fence digest attachment and reclamation"
```

### Task 5: Stream uploads through the exact arity-two reader contract

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/upload.ex`
- Create: `apps/forge_releases/test/support/fixtures.ex`
- Create: `apps/forge_releases/test/support/fault_asset_storage.ex`
- Create: `apps/forge_releases/test/asset_upload_test.exs`
- Modify: `apps/forge_releases/lib/forge_releases.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_operation.ex`
- Modify: `apps/forge_releases/test/test_helper.exs`

- [ ] Add a small storage fault seam and failing tests for admission-before-read, exact state threading, successful upload, deduplication, lower configured cap, exact-cap EOF, one-byte overflow, a zero-progress `{:more, <<>>, state}` reader, reader error/exception, idle/total timeout, pre-stream abort, ambiguous commit, lost ownership, and exact-once compensation. Assert zero-progress fails immediately without resetting the idle deadline or spinning; terminal `{:ok, <<>>, state}` remains the one permitted empty terminal result. Add an attachment race where GC or audit holds the digest lease and local task fence: assert the upload renews its own operation while bounded-retrying, does not discard or compensate the staged bytes on routine overlap, and succeeds after the competing task reaches `:DOWN` and releases/reconciles its blob lease:

```elixir
defmodule ForgeReleases.FaultAssetStorage do
  @behaviour ForgeReleases.AssetStorage

  def ready?, do: dispatch(:ready?, [])
  def capacity, do: dispatch(:capacity, [])
  def stage_from_reader(key, reader, state, options),
    do: dispatch(:stage_from_reader, [key, reader, state, options])
  def commit(staged), do: dispatch(:commit, [staged])
  def discard(staged), do: dispatch(:discard, [staged])
  def stat(key), do: dispatch(:stat, [key])
  def open(key, size, range), do: dispatch(:open, [key, size, range])
  def read(source, bytes), do: dispatch(:read, [source, bytes])
  def close(source), do: dispatch(:close, [source])
  def verify(key), do: dispatch(:verify, [key])
  def delete(key), do: dispatch(:delete, [key])
  def recover_stage(key, digest, size), do: dispatch(:recover_stage, [key, digest, size])
  def cleanup_staging(key), do: dispatch(:cleanup_staging, [key])

  defp dispatch(function, arguments) do
    handler = Application.fetch_env!(:forge_releases, :fault_asset_storage_handler)
    handler.(function, arguments)
  end
end
```

Tests set the handler in serial setup to a closure that sends observations to the test PID and delegates or injects a result, then restore the previous application value in `on_exit/1`. Do not use the process dictionary because commit/recovery/GC effects run in different processes.

```elixir
test "exact cap probes once more for EOF and rejects one extra byte", context do
  upload = begin_upload!(context, max_bytes: 4)
  parent = self()

  reader = fn
    %{chunks: [chunk | rest], calls: calls} = state, options ->
      send(parent, {:read_options, options})
      {:more, chunk, %{state | chunks: rest, calls: calls + 1}}

    %{chunks: [], calls: calls} = state, options ->
      send(parent, {:read_options, options})
      {:done, %{state | calls: calls + 1}}
  end

  assert {:ok, asset, %{calls: 2}} =
           ForgeReleases.stream_asset_upload(upload, reader, %{chunks: ["four"], calls: 0})
  assert asset.size == 4
  assert_receive {:read_options, first}
  assert first[:length] == 5
  assert_receive {:read_options, probe}
  assert probe[:length] == 1

  overflow = begin_upload!(context, name: "overflow.bin", max_bytes: 4)

  assert {:error, {:payload_too_large, :asset}, %{calls: 2}} =
           ForgeReleases.stream_asset_upload(
             overflow,
             reader,
             %{chunks: ["four", "!"] , calls: 0}
           )
end

test "abort is valid only before streaming begins", context do
  upload = begin_upload!(context)
  assert :ok = ForgeReleases.abort_asset_upload(upload, {:request_timeout, :asset})
  assert :ok = ForgeReleases.abort_asset_upload(upload, {:request_timeout, :asset})
  assert Repo.aggregate(Asset, :count) == 0
  assert get_release!(context).asset_count == 0
end

test "abort reports unavailable when durable compensation cannot commit", context do
  upload = begin_upload!(context, name: "blocked-abort.bin")
  inject_transaction_failure!(:abort_compensation)

  assert {:error, {:unavailable, :release_persistence}} =
           ForgeReleases.abort_asset_upload(upload, {:request_timeout, :asset})

  assert Repo.get!(AssetOperation, upload_operation_id(upload)).state == :staging
end
```

Use a sparse/counter reader for the immutable 2,147,483,648-byte boundary; never allocate that binary. Assert the callback always receives positive `:length`, `:read_length`, and `:read_timeout`; `:length` is at most 1 MiB, `:read_length <= :length`, and `:read_timeout` is at most 30 seconds. Return a chunk one byte larger than the supplied `:length` and assert the domain reader wrapper rejects it while preserving that callback's newest state; Plan 1 independently enforces its adapter-level ceiling. Separately force timeout and lease-loss classifications and assert every result returns the exact latest reader state: timeout compensates and becomes `{:request_timeout, :asset}` (HTTP 408 at the API boundary), while `:lost_lease` returns unavailable without stale discard or compensation. Reader state is never inspected or logged.

- [ ] Run the focused upload suite and confirm the upload domain is absent:

```bash
mix test apps/forge_releases/test/asset_upload_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.Upload`, `begin_asset_upload/5`, and `stream_asset_upload/3`.

- [ ] Implement the opaque upload handle and atomic admission. The handle's inspection reveals no owner, token, deadlines, staging key, or request metadata:

```elixir
defmodule ForgeReleases.Upload do
  @moduledoc false

  @enforce_keys [:asset, :operation, :max_bytes, :idle_ms, :total_ms]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{}
end

defimpl Inspect, for: ForgeReleases.Upload do
  def inspect(_upload, _options), do: "#ForgeReleases.Upload<redacted>"
end
```

Build admission as one `Ecto.Multi`: authorize first; conditionally increment `releases.asset_count` only for an available release below 1,000; insert the pending asset to reserve `{release_id, name}`; insert a leased `AssetOperation{kind: :upload, state: :staging}`; then update its `staging_key` to `"upload-#{operation.id}-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"`. Return no handle until all four operations commit. Convert the unique-index race to the existing validation shape without reading request bytes.

Use this state-qualified quota update:

```elixir
quota_query =
  from release in Release,
    where:
      release.id == ^release.id and release.repository_id == ^repository.id and
        release.state == :available and release.asset_count < 1_000

Ecto.Multi.update_all(multi, :reserve_quota, quota_query, inc: [asset_count: 1])
```

- [ ] Implement the deadline reader wrapper. Immediately renew ownership when streaming starts so the original upload handle becomes stale; compute fresh options before every raw reader call; probe one extra byte at the cap; enforce 30-second rolling idle and fixed 30-minute total deadlines; and thread both raw state and the newest leased operation:

```elixir
defp deadline_reader(raw_reader, %Upload{} = upload, reader_state, clock) do
  started = clock.monotonic_ms.()

  case Fornacast.OperationLease.renew_owned(
         AssetOperation,
         upload.operation,
         now: clock.utc_now.(),
         lease_seconds: 60
       ) do
    {:ok, operation} ->

  initial = %{
    raw_state: reader_state,
    operation: operation,
    bytes: 0,
    total_deadline: started + upload.total_ms,
    idle_deadline: started + upload.idle_ms,
    renew_at: started + 30_000,
    reader_error: nil
  }

  wrapped = fn state, _adapter_options ->
    now_ms = clock.monotonic_ms.()
    total_remaining = state.total_deadline - now_ms
    idle_remaining = state.idle_deadline - now_ms

    if total_remaining <= 0 or idle_remaining <= 0 do
      {:error, :deadline, %{state | reader_error: :timeout}}
    else
      remaining_bytes = upload.max_bytes - state.bytes
      probe_bytes = max(remaining_bytes + 1, 1)
      length = min(1_048_576, probe_bytes)

      read_options = [
        length: length,
        read_length: min(65_536, length),
        read_timeout: Enum.min([total_remaining, idle_remaining, 30_000])
      ]

      with {:ok, state} <- renew_if_due(state, clock),
           result <- safe_reader_call(raw_reader, state.raw_state, read_options) do
        consume_reader_result(
          result,
          state,
          remaining_bytes,
          length,
          clock.monotonic_ms.(),
          upload.idle_ms
        )
      else
        {:error, :lost_lease} -> {:error, :lost_lease, %{state | reader_error: :lost_lease}}
      end
    end
  end

      {:ok, wrapped, initial}

    {:error, :lost_lease} ->
      {:error, :lost_lease, reader_state}
  end
end

defp safe_reader_call(reader, raw_state, read_options) do
  try do
    reader.(raw_state, read_options)
  rescue
    _error -> {:error, :reader_exception, raw_state}
  catch
    _kind, _reason -> {:error, :reader_exception, raw_state}
  end
end

defp consume_reader_result(
       {:more, <<>>, raw_state},
       state,
       _remaining,
       _maximum_chunk,
       _now_ms,
       _idle_ms
     ),
  do: {:error, :reader_no_progress, %{state | raw_state: raw_state, reader_error: :reader}}

defp consume_reader_result(
       {:ok, <<>>, raw_state},
       state,
       _remaining,
       _maximum_chunk,
       _now_ms,
       _idle_ms
     ),
  do: {:ok, <<>>, %{state | raw_state: raw_state}}

defp consume_reader_result(
       {kind, bytes, raw_state},
       state,
       remaining,
       maximum_chunk,
       now_ms,
       idle_ms
     )
     when kind in [:more, :ok] and is_binary(bytes) and byte_size(bytes) > 0 do
  cond do
    byte_size(bytes) > maximum_chunk ->
      {:error, :reader_chunk_too_large,
       %{state | raw_state: raw_state, reader_error: :reader}}

    byte_size(bytes) > remaining ->
      {:error, :entity_too_large,
       %{state | raw_state: raw_state, reader_error: :entity_too_large}}

    true ->
      next = %{
        state
        | raw_state: raw_state,
          bytes: state.bytes + byte_size(bytes),
          idle_deadline: now_ms + idle_ms
      }

      {kind, bytes, next}
  end
end

defp consume_reader_result(
       {:done, raw_state},
       state,
       _remaining,
       _maximum_chunk,
       _now_ms,
       _idle_ms
     ),
  do: {:done, %{state | raw_state: raw_state}}

defp consume_reader_result(
       {:error, reason, raw_state},
       state,
       _remaining,
       _maximum_chunk,
       _now_ms,
       _idle_ms
     ),
  do: {:error, reason, %{state | raw_state: raw_state, reader_error: :reader}}
```

Catch callback exceptions at this boundary, retain the latest pre-call reader state, mark `reader_error: :reader`, and route it through ordinary compensation. `renew_if_due/2` calls `OperationLease.renew_owned/3`, replaces `state.operation`, and advances `renew_at`; it never reuses a stale row. The supplied `:read_timeout` is cooperative input to the raw callback; it does not preempt a callback that ignores the option, so the request/connection owner remains responsible for its outer deadline.

- [ ] Implement stage, blob attach, monitored commit/stat, metadata visibility, and exact success-shape checks. The adapter's arity-one ESS wrapper remains Plan 1's responsibility; this domain wrapper is the arity-two callback it receives:

```elixir
def stream_asset_upload(%Upload{} = upload, reader, reader_state) when is_function(reader, 2) do
  storage = storage_module()
  clock = clock_module()

  case deadline_reader(reader, upload, reader_state, clock) do
    {:ok, wrapped_reader, stream_state} ->
      case storage.stage_from_reader(
             upload.operation.staging_key,
             wrapped_reader,
             stream_state,
             max_size: upload.max_bytes,
             read_options: [
               length: 1_048_576,
               read_length: 65_536,
               read_timeout: min(upload.idle_ms, 30_000)
             ]
           ) do
        {:ok, staged_ref, metadata, final_state} ->
          finish_staged_upload(upload, staged_ref, metadata, final_state)

        {:error, reason, final_state} ->
          finish_stage_error(upload, reason, final_state)
      end

    {:error, :lost_lease, latest_reader_state} ->
      {:error, {:unavailable, :asset_storage}, latest_reader_state}
  end
end

defp finish_stage_error(_upload, _reason, %{reader_error: :lost_lease} = state) do
  {:error, {:unavailable, :asset_storage}, state.raw_state}
end

defp finish_stage_error(upload, reason, %{reader_error: :timeout} = state) do
  compensate_stream_error(
    upload,
    state.operation,
    reason,
    state.raw_state,
    {:request_timeout, :asset}
  )
end

defp finish_stage_error(upload, reason, state) do
  compensate_stream_error(upload, state.operation, reason, state.raw_state)
end

defp finish_staged_upload(upload, staged_ref, metadata, state) do
  case exact_metadata?(metadata) do
    :ok ->
      deadline = clock_module().monotonic_ms.() + 30_000

      case attach_with_retry(state.operation, metadata, deadline) do
        {:ok, operation, _blob} ->
          commit_attached_upload(upload, staged_ref, metadata, state.raw_state, operation)

        {:error, :busy_deleting, newest} ->
          _result = OperationLease.release(AssetOperation, newest)
          {:error, {:unavailable, :asset_storage}, state.raw_state}

        {:error, reason, newest} ->
          compensate_after_stage(upload, staged_ref, newest, reason, state.raw_state)

        {:error, :lost_lease} ->
          {:error, {:unavailable, :asset_storage}, state.raw_state}
      end

    {:error, reason} ->
      compensate_after_stage(upload, staged_ref, state.operation, reason, state.raw_state)
  end
end

defp attach_with_retry(operation, metadata, deadline) do
  with {:ok, newest} <-
         OperationLease.renew_owned(AssetOperation, operation,
           now: utc_now(),
           lease_seconds: 60
         ) do
    case BlobInventory.attach(newest, metadata.sha256_digest, metadata.size,
           now: utc_now(),
           lease_seconds: 60
         ) do
      {:ok, _operation, _blob} = attached ->
        attached

      {:error, :busy_deleting} ->
        remaining = deadline - clock_module().monotonic_ms.()

        if remaining > 0 do
          Process.sleep(min(100, remaining))
          attach_with_retry(newest, metadata, deadline)
        else
          {:error, :busy_deleting, newest}
        end

      {:error, :lost_lease} ->
        {:error, :lost_lease}

      {:error, reason} ->
        {:error, reason, newest}
    end
  else
    {:error, :lost_lease} -> {:error, :lost_lease}
  end
end

defp commit_attached_upload(upload, staged_ref, metadata, reader_state, operation) do
  case MonitoredWork.run(AssetOperation, operation, fn ->
         with {:ok, committed} <- storage_module().commit(staged_ref),
              {:ok, %{size: size}} when size == committed.size <-
                storage_module().stat(committed.storage_key) do
           {:ok, committed}
         end
       end,
         task_supervisor: ForgeReleases.WorkTaskSupervisor,
         lease_seconds: 60,
         renew_after_ms: 30_000,
         timeout_ms: 120_000
       ) do
    {:ok, committed, newest} when committed == metadata ->
      with {:ok, newest} <- persist_metadata_ready(upload.asset, newest, committed),
           {:ok, asset} <- complete_upload(upload.asset, newest) do
        _best_effort = storage_module().discard(staged_ref)
        {:ok, asset, reader_state}
      else
        {:error, _reason} -> {:error, {:unavailable, :release_persistence}, reader_state}
      end

    {:ok, _mismatch, newest} ->
      compensate_after_stage(upload, staged_ref, newest, :integrity_mismatch, reader_state)

    {:error, :ambiguous_commit, _newest} ->
      {:error, {:unavailable, :asset_storage}, reader_state}

    {:error, reason, newest} ->
      compensate_after_stage(upload, staged_ref, newest, reason, reader_state)

    {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] ->
      {:error, {:unavailable, :asset_storage}, reader_state}
  end
end
```

`persist_metadata_ready/3` atomically marks the blob ready after commit/stat, fills the still-pending asset's size/digest/storage key, and owner-retains the operation at `metadata_ready`. `complete_upload/2` atomically makes the asset available, records `release_asset.created` with `operation_id: "release_asset_operation:<id>"`, and uses releasing `OperationLease.update_owned/3` to mark completed. Success returns only after that commit.

The five-argument `compensate_stream_error/5` performs the same exact-once
durable compensation as the ordinary four-argument form but returns its supplied
public error only after that transaction commits; a persistence failure still
returns `{:unavailable, :release_persistence}`. Inspect `reader_error` before any
compensation. In particular, a lease-loss final state may contain an obsolete
operation version, so it returns unavailable immediately and performs no
discard, staging cleanup, or metadata mutation. Tests must make the fault storage
return both classifications with distinct newest raw states and assert those
states are returned unchanged.

The 30-second attachment deadline is monotonic and testable through the existing clock seam. `:busy_deleting` is coordination, not payload failure: after bounded retries it releases only the newest upload lease and returns unavailable, retaining the operation and staging key for recovery. Never route a two-tuple no-row ownership result through compensation. A later request/recovery pass may attach after the competing task is down; routine overlap must not consume or discard staged content.

The post-terminal `discard/1` is best-effort only. The operation retains its logical staging key until Task 7's bounded terminal-cleanup pass confirms `cleanup_staging/1` succeeded and clears it; a discard failure must not turn committed visible metadata back into an upload failure.

- [ ] Implement exact-once compensation and pre-stream abort. Ordinary reader, timeout, overflow, stage, deterministic commit, and close errors delete the pending asset and decrement quota only if that delete affected one row; ambiguous commit or lost ownership leaves `staged` for recovery and performs no cleanup:

```elixir
defp compensate_upload(asset, operation, failure_reason) do
  Ecto.Multi.new()
  |> Ecto.Multi.delete_all(
    :asset,
    from(item in Asset, where: item.id == ^asset.id and item.state == :pending)
  )
  |> Ecto.Multi.run(:quota, fn repo, %{asset: {count, _rows}} ->
    if count == 1 do
      {updated, _rows} =
        repo.update_all(
          from(release in Release,
            where: release.id == ^asset.release_id and release.asset_count > 0
          ),
          inc: [asset_count: -1]
        )

      if updated == 1, do: {:ok, :released}, else: {:error, :state_changed}
    else
      {:ok, :already_released}
    end
  end)
  |> Ecto.Multi.run(:operation, fn _repo, _changes ->
    Fornacast.OperationLease.update_owned(
      AssetOperation,
      operation,
      state: :failed,
      failure_reason: AssetOperation.sanitize_failure_reason(failure_reason)
    )
  end)
  |> Repo.transaction()
end
```

`abort_asset_upload/2` executes this only with the original `staging` owner/version; a second abort is idempotent and an abort after streaming began sees `:lost_lease` and performs nothing. If compensation storage/SQL is unavailable, return normalized unavailable and leave the durable nonterminal operation for recovery rather than claiming cleanup succeeded.

- [ ] Run upload tests under several seeds and commit:

```bash
mix format apps/forge_releases/lib/forge_releases/{upload,asset,asset_operation}.ex \
  apps/forge_releases/lib/forge_releases.ex \
  apps/forge_releases/test/{asset_upload_test.exs,test_helper.exs} \
  apps/forge_releases/test/support/{fixtures,fault_asset_storage}.ex
for seed in 0 1 2; do
  mix test apps/forge_releases/test/asset_upload_test.exs --max-cases 1 --seed "$seed" || exit 1
done
```

Expected: all runs report `0 failures`; exact cap performs a positive one-byte EOF probe, overflow compensates once, ambiguous/lost-owner cases remain recoverable, and identical uploads share one ready digest row.

```bash
git add apps/forge_releases/lib/forge_releases.ex \
  apps/forge_releases/lib/forge_releases/{upload,asset,asset_operation}.ex \
  apps/forge_releases/test/asset_upload_test.exs \
  apps/forge_releases/test/support/{fixtures,fault_asset_storage}.ex \
  apps/forge_releases/test/test_helper.exs
git commit -m "feat(releases): stream assets into LocalCAS"
```

### Task 6: Serve descriptor-backed downloads and delete metadata immediately

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/asset_download.ex`
- Create: `apps/forge_releases/test/asset_download_test.exs`
- Create: `apps/forge_releases/test/deletion_test.exs`
- Modify: `apps/forge_releases/test/blob_inventory_test.exs`
- Modify: `apps/forge_releases/lib/forge_releases.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_operation.ex`
- Modify: `apps/forge_releases/lib/forge_releases/blob_inventory.ex`

- [ ] Add failing download tests for authorization before storage lookup, redacted inspection, expected-size open, bounded reads, empty/oversized/malformed adapter-result normalization with descriptor close, exact EOF, fixed total deadline, rolling idle deadline, idempotent close, post-unlink descriptor reads, crash/fresh-BEAM ready-lease reclamation, slow-open expiry, and completion-only download counting:

```elixir
test "open owns a descriptor and every domain read is at most one MiB", context do
  asset = uploaded_asset!(context, String.duplicate("x", 1_048_577))
  assert {:ok, download} = ForgeReleases.open_asset(context.repo, asset, context.reader)
  assert inspect(download) == "#ForgeReleases.AssetDownload<redacted>"

  assert %{size: 1_048_577, content_type: "application/octet-stream"} =
           ForgeReleases.asset_download_metadata(download)

  assert {:ok, first, download} = ForgeReleases.read_asset_chunk(download, 9_000_000)
  assert byte_size(first) == 1_048_576
  assert {:ok, "x", download} = ForgeReleases.read_asset_chunk(download, 9_000_000)
  assert :eof = ForgeReleases.read_asset_chunk(download, 1)
  assert :ok = ForgeReleases.close_asset_download(download)
  assert :ok = ForgeReleases.close_asset_download(download)
end

test "a private unauthorized lookup never opens storage", context do
  install_fault_observer!(self())
  assert {:error, :not_found} = ForgeReleases.open_asset(context.private_repo, context.asset, nil)
  refute_receive {:open, _arguments}
end

test "a fresh BEAM reclaims an expired ready open lease", context do
  asset = uploaded_asset!(context, "bytes")
  strand_ready_open_lease!(asset.storage_key, "dead-request", expired_now())
  restart_recovery_supervision!()

  assert {:ok, download} = ForgeReleases.open_asset(context.repo, asset, context.reader)
  assert {:ok, "bytes", download} = ForgeReleases.read_asset_chunk(download, 1_048_576)
  assert Repo.get_by!(ReleaseAssetBlob, sha256_digest: asset.storage_key).lease_owner == nil
end

test "a slow stale opener closes and fails after an expired lease is reclaimed", context do
  asset = uploaded_asset!(context, "slow")
  first = pause_open_after_ready_claim!(context, asset)
  advance_utc_clock!(31)

  assert {:ok, second} = ForgeReleases.open_asset(context.repo, asset, context.reader)
  resume_paused_open!(first)

  assert {:error, {:unavailable, :asset_storage}} = Task.await(first.task)
  assert_receive {:close, first_source}
  assert {:ok, "slow", second} = ForgeReleases.read_asset_chunk(second, 1_048_576)
end
```

Also kill a request after its ready claim but before `AssetStorage.open/3`; assert the SQL lease remains until expiry, a pre-expiry open is unavailable, and the first post-expiry open reclaims it. Repeat with an active `TaskFence` held beyond expiry and assert no reclaim occurs until exact `:DOWN`. Assert `record_download/2` uses one SQL increment after the caller reports completed EOF handling; a disconnect/read error does not call it; two concurrent completions increment twice. Add a same-size corruption case whose bytes still open successfully at the adapter but whose blob ledger is already `corrupt`; assert `open_asset/3` returns `{:error, {:unavailable, :asset_storage}}` without calling `AssetStorage.open/3`.

- [ ] Add failing metadata/deletion tests. Cover rename collision, forbidden field changes, update/delete race with no orphan audit, immediate invisibility, quota adjustment once, duplicate delete, shared-digest safety, duplicate content in one release, bulk release deletion restart points, and no foreground `AssetStorage.delete/1` call:

```elixir
test "deleting one shared asset leaves bytes reachable by the other", context do
  first = uploaded_asset!(context, "shared bytes", name: "first.bin")
  second = uploaded_asset!(context, "shared bytes", name: "second.bin")
  assert first.storage_key == second.storage_key

  install_fault_observer!(self())
  assert :ok = ForgeReleases.delete_asset(context.repo, first, context.writer, safe_request("delete-first"))
  refute_receive {:delete, _arguments}
  assert {:error, :not_found} = ForgeReleases.get_asset(context.repo, first.id, context.writer)
  assert {:ok, download} = ForgeReleases.open_asset(context.repo, second, context.writer)
  assert {:ok, "shared bytes", download} = ForgeReleases.read_asset_chunk(download, 1_048_576)
end

test "delete admission hides the asset before terminal bookkeeping", context do
  asset = uploaded_asset!(context, "bytes")
  pause_after!(:asset_delete_admitted)
  task = Task.async(fn -> delete_asset!(context, asset) end)
  assert_receive :asset_delete_admitted
  assert {:error, :not_found} = ForgeReleases.get_asset(context.repo, asset.id, context.writer)
  resume!(:asset_delete_admitted)
  assert :ok = Task.await(task)
end
```

- [ ] Run both focused files and verify the new handle/deletion behavior is absent:

```bash
mix test apps/forge_releases/test/asset_download_test.exs \
  apps/forge_releases/test/deletion_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.AssetDownload`, `open_asset/3`, `read_asset_chunk/2`, and asset deletion functions.

- [ ] Implement the opaque download handle and descriptor-only reads. `open_asset/3` authorizes and constrains an available asset through its release/repository before calling storage. It then atomically claims the matching `ready` blob row through `BlobInventory.claim_ready/5` and performs `open/3` in the same request process while that short SQL claim is held. A missing, leased, non-ready, wrong-size, or `corrupt` ledger row fails closed before storage is opened:

```elixir
defmodule ForgeReleases.AssetDownload do
  @moduledoc false

  @enforce_keys [
    :source,
    :size,
    :remaining,
    :content_type,
    :disposition,
    :total_deadline,
    :idle_deadline
  ]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{}
end

defimpl Inspect, for: ForgeReleases.AssetDownload do
  def inspect(_download, _options), do: "#ForgeReleases.AssetDownload<redacted>"
end

defp open_authorized_asset(asset, clock) do
  owner = lease_owner("asset-open", System.unique_integer([:positive]))

  case BlobInventory.claim_ready(asset.storage_key, asset.size, owner, utc_now(), 30) do
    {:ok, blob} ->
      open_claimed_asset(blob, asset, clock)

    :busy ->
      {:error, {:unavailable, :asset_storage}}

    :not_ready ->
      {:error, {:unavailable, :asset_storage}}

    {:error, _reason} ->
      {:error, {:unavailable, :asset_storage}}
  end
end

defp open_claimed_asset(blob, asset, clock) do
  case storage_module().open(asset.storage_key, asset.size, :all) do
    {:ok, source} ->
      case OperationLease.release(ReleaseAssetBlob, blob) do
        :ok ->
          now = clock.monotonic_ms.()

          {:ok,
           %AssetDownload{
             source: source,
             size: asset.size,
             remaining: asset.size,
             content_type: asset.content_type,
             disposition: content_disposition(asset.name),
             total_deadline: now + 1_800_000,
             idle_deadline: now + 30_000
           }}

        {:error, _reason} ->
          _close = storage_module().close(source)
          {:error, {:unavailable, :asset_storage}}
      end

    {:error, :integrity_mismatch} ->
      _result =
        OperationLease.update_owned(ReleaseAssetBlob, blob,
          state: :corrupt,
          integrity_failure: "size_mismatch"
        )

      {:error, {:unavailable, :asset_storage}}

    {:error, _reason} ->
      _result = OperationLease.release(ReleaseAssetBlob, blob)
      {:error, {:unavailable, :asset_storage}}
  end
end
```

Add the state/version-qualified inventory claim used above:

```elixir
def claim_ready(digest, size, owner, now, lease_seconds) do
  case Repo.get_by(ReleaseAssetBlob, sha256_digest: digest, size: size) do
    nil ->
      :not_ready

    observed ->
      if TaskFence.active?({ReleaseAssetBlob, observed.id}) do
        :busy
      else
        expires_at = DateTime.add(now, lease_seconds, :second)

        query =
          from blob in ReleaseAssetBlob,
            where:
              blob.id == ^observed.id and blob.lock_version == ^observed.lock_version and
                blob.sha256_digest == ^digest and blob.size == ^size and
                blob.state == :ready and
                (is_nil(blob.lease_owner) or
                   (not is_nil(blob.lease_expires_at) and blob.lease_expires_at <= ^now))

        case Repo.update_all(query,
               set: [lease_owner: owner, lease_expires_at: expires_at],
               inc: [lock_version: 1]
             ) do
          {1, _rows} -> {:ok, Repo.get!(ReleaseAssetBlob, observed.id)}
          {0, _rows} -> classify_ready_claim_conflict(observed.id, digest, size)
        end
      end
  end
end
```

`classify_ready_claim_conflict/3` performs one read only: a non-ready/missing/wrong-size row returns `:not_ready`; an active fence, an unexpired owner, or a version race returns `:busy`. It never changes state.

`BlobInventory.claim_ready/5` first loads the digest/size row, rejects an active `TaskFence`, then uses one observed-version and state-qualified update requiring `state == :ready`, the exact digest/size/version, and either no owner or an expired lease. This is a direct takeover: setting the new owner and incrementing `lock_version` are atomic, so there is no unowned gap. A state/version/fence race returns `:not_ready` or `:busy` before I/O. Keep `AssetStorage.open/3` in the request process because the raw file descriptor is controlling-process-affine; do not return a `Source` from `MonitoredWork` or any spawned task. The short SQL claim linearizes opening against an audit transition to `corrupt`, then releases as soon as the descriptor is open. If release loses ownership—including because a slow open exceeded 30 seconds and a later request reclaimed the lease—or otherwise fails, close the just-opened descriptor and return unavailable; never return a handle whose opening claim was not cleanly released. A request crash may leave only the durable lease; after expiry and with no active local fence, a same-version `ready` claimant, attachment, recovery/audit, or unreferenced-GC path can reclaim it. These on-demand state/version-qualified paths are the ready-lease recovery mechanism; do not add an unsafe timer that clears owners without checking state, version, and `TaskFence`. An already-open descriptor remains readable across later logical deletion, candidate marking, or audit state changes under the one-hour GC grace and 30-minute handle deadline because its claim was released before the handle returned; reads and close do not consult or renew the blob lease. Every future open fails once the ledger is non-ready. Construct `Content-Disposition` from sanitized metadata only; reject CR/LF and control characters in asset names during upload/update validation.

- [ ] Implement 1 MiB-clamped reads, exact EOF, deadlines, and idempotent close:

```elixir
def read_asset_chunk(%AssetDownload{remaining: 0}, requested)
    when is_integer(requested) and requested > 0,
    do: :eof

def read_asset_chunk(%AssetDownload{} = download, requested)
    when is_integer(requested) and requested > 0 do
  now = clock_module().monotonic_ms.()

  cond do
    now >= download.total_deadline or now >= download.idle_deadline ->
      {:error, {:request_timeout, :asset}}

    true ->
      bytes = min(requested, min(1_048_576, download.remaining))

      case storage_module().read(download.source, bytes) do
        {:ok, chunk, source} when byte_size(chunk) in 1..bytes ->
          {:ok, chunk,
           %{
             download
             | source: source,
               remaining: download.remaining - byte_size(chunk),
               idle_deadline: now + 30_000
           }}

        :eof ->
          _close = storage_module().close(download.source)
          {:error, {:unavailable, :asset_storage}}

        {:error, _reason} ->
          _close = storage_module().close(download.source)
          {:error, {:unavailable, :asset_storage}}

        {:ok, _invalid_chunk, source} ->
          _close = storage_module().close(source)
          {:error, {:unavailable, :asset_storage}}

        _malformed ->
          _close = storage_module().close(download.source)
          {:error, {:unavailable, :asset_storage}}
      end
  end
end

def close_asset_download(%AssetDownload{source: source}), do: storage_module().close(source)
```

Return `:eof` only after recorded bytes are consumed. Empty non-EOF, oversized, or malformed adapter chunks are normalized storage-integrity failures: close the newest source available (otherwise the current source) and return `{:error, {:unavailable, :asset_storage}}`, never raise a `CaseClauseError`. Reads and close remain in the request process and touch no SQL; the ready-ledger check belongs only to opening. `record_download/2` executes a repository/release/asset-scoped `Repo.update_all(query, inc: [download_count: 1])` and requires one available row; it never performs read/modify/write.

- [ ] Implement metadata update and logical asset deletion. Update only `name` and `label` through one state-qualified multi with `release_asset.updated` audit. Delete admission inserts a leased delete operation and changes exactly one available asset to `deleting` in the same transaction:

```elixir
defp available_asset_query(repository_id, asset_id) do
  from asset in Asset,
    join: release in Release,
    on: release.id == asset.release_id,
    where:
      asset.id == ^asset_id and asset.state == :available and
        release.repository_id == ^repository_id and release.state == :available,
    select: asset
end

defp update_asset_metadata(repository, asset, attrs, actor, request_meta) do
  with {:ok, values} <- Asset.validate_metadata_update(asset, attrs) do
    query = available_asset_query(repository.id, asset.id)

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :updated,
      query,
      set: [name: values.name, label: values.label, updated_at: utc_now()]
    )
    |> Ecto.Multi.run(:asset, fn repo, %{updated: {count, _rows}} ->
      if count == 1,
        do: {:ok, repo.one!(available_asset_query(repository.id, asset.id))},
        else: {:error, {:conflict, :state_changed}}
    end)
    |> Fornacast.Audit.record_multi(
      :audit,
      actor,
      "release_asset.updated",
      "release_asset",
      fn %{asset: updated} -> Integer.to_string(updated.id) end,
      %{repository_id: repository.id, release_id: asset.release_id},
      request_metadata: request_meta
    )
    |> Repo.transaction()
  end
end

defp admit_asset_delete(repository, asset, actor, request_meta) do
  now = utc_now()
  owner = lease_owner("asset-delete", request_meta.request_id)

  Ecto.Multi.new()
  |> Ecto.Multi.update_all(
    :hide_asset,
    from(item in Asset,
      where:
        item.id == ^asset.id and item.release_id == ^asset.release_id and
          item.state == :available
    ),
    set: [state: :deleting]
  )
  |> Ecto.Multi.run(:operation, fn repo, %{hide_asset: {1, _rows}} ->
    repo.insert(
      AssetOperation.prepare_changeset(%AssetOperation{}, %{
        asset_id: asset.id,
        asset_record_id: asset.id,
        release_record_id: asset.release_id,
        repository_id: repository.id,
        actor_user_id: actor.id,
        kind: :delete,
        state: :deleting,
        request_id: request_meta.request_id,
        lease_owner: owner,
        lease_expires_at: DateTime.add(now, 30, :second)
      })
    )
  end)
  |> Repo.transaction()
end
```

Handle the zero-row form in a separate `Ecto.Multi.run` clause as `{:error, {:conflict, :state_changed}}`; do not allow a function-clause crash.

- [ ] Finish logical deletion without touching LocalCAS. Retain blob reachability through the deleting asset until the metadata transaction commits; then delete metadata, decrement `asset_count` once, record audit, and terminally release the operation together:

```elixir
defp finish_asset_delete(asset, operation, request_meta) do
  Ecto.Multi.new()
  |> Ecto.Multi.delete_all(
    :asset,
    from(item in Asset, where: item.id == ^asset.id and item.state == :deleting)
  )
  |> Ecto.Multi.run(:quota, fn repo, %{asset: {count, _rows}} ->
    if count == 1 do
      {updated, _rows} =
        repo.update_all(
          from(release in Release,
            where: release.id == ^asset.release_id and release.asset_count > 0
          ),
          inc: [asset_count: -1]
        )

      if updated == 1, do: {:ok, :released}, else: {:error, :state_changed}
    else
      {:ok, :already_deleted}
    end
  end)
  |> Fornacast.Audit.record_multi(
    :audit,
    audit_actor(operation.actor_user_id),
    "release_asset.deleted",
    "release_asset",
    Integer.to_string(operation.asset_record_id),
    %{repository_id: operation.repository_id, release_id: operation.release_record_id},
    request_metadata: request_meta,
    operation_id: "release_asset_operation:#{operation.id}"
  )
  |> Ecto.Multi.run(:operation, fn _repo, _changes ->
    Fornacast.OperationLease.update_owned(AssetOperation, operation, state: :deleted)
  end)
  |> Repo.transaction()
  |> normalize_delete_result()
end
```

The release-deletion loop calls an internal idempotent form that admits at most 50 available assets per pass, resumes already-deleting assets, and advances the release operation only when no release assets remain. Shared/duplicate digest bytes are untouched until BlobGC.

- [ ] Run the focused suite repeatedly and commit:

```bash
mix format apps/forge_releases/lib/forge_releases/{asset_download,asset,asset_operation,blob_inventory}.ex \
  apps/forge_releases/lib/forge_releases.ex \
  apps/forge_releases/test/{asset_download_test,blob_inventory_test,deletion_test}.exs
for seed in 0 1 2; do
  mix test apps/forge_releases/test/asset_download_test.exs \
    apps/forge_releases/test/blob_inventory_test.exs \
    apps/forge_releases/test/deletion_test.exs --max-cases 1 --seed "$seed" || exit 1
done
```

Expected: all runs report `0 failures`; download handles contain only opaque descriptors, metadata hides immediately, shared content stays readable, and no foreground delete invokes LocalCAS deletion.

```bash
git add apps/forge_releases/lib/forge_releases.ex \
  apps/forge_releases/lib/forge_releases/{asset_download,asset,asset_operation,blob_inventory}.ex \
  apps/forge_releases/test/{asset_download_test,blob_inventory_test,deletion_test}.exs
git commit -m "feat(releases): serve and logically delete assets"
```

### Task 7: Reconcile every persisted release, upload, and logical-delete state

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/recovery.ex`
- Create: `apps/forge_releases/lib/forge_releases/recovery_scheduler.ex`
- Create: `apps/forge_releases/test/recovery_test.exs`
- Modify: `apps/forge_releases/lib/forge_releases/recovery_supervisor.ex`
- Modify: `apps/forge_releases/lib/forge_releases.ex`

- [ ] Add a table-driven fault suite that exits after every persisted nonterminal state and runs recovery twice. Assert one terminal result, one audit event, no partial visibility, no tag movement, exact-once quota, and terminal staging cleanup:

```elixir
for {kind, state} <- [
      {:publish, :prepared},
      {:publish, :tag_ready},
      {:publish, :metadata_ready},
      {:upload, :staging},
      {:upload, :staged},
      {:upload, :metadata_ready},
      {:asset_delete, :deleting},
      {:release_delete, :deleting},
      {:release_delete, :assets_deleted},
      {:release_delete, :metadata_deleted}
    ] do
  test "recovers #{kind} after #{state} idempotently", context do
    operation = persisted_fault!(context, unquote(kind), unquote(state))
    assert :ok = Recovery.reconcile_operation(operation)
    assert :ok = Recovery.reconcile_operation(Repo.reload!(operation))
    assert_terminal_invariants!(context, unquote(kind), operation.id)
  end
end
```

Add the complete staged-upload matrix: already-ready digest; one valid regular survivor; missing survivor; symlink; nested entry; multiple entries; oversized file; survivor size mismatch; survivor digest mismatch; transient stage/stat/verify failures; ambiguous recovery commit; confirmed metadata-ready missing/corruption; and a concurrent ready blob appearing before the required second stat. Each branch runs twice. Pause each initial staged stat/verify, metadata-ready stat/verify, and post-survivor second stat/verify beyond the original 30-second lease; assert renewal advances `lock_version`, the returned newest row is threaded into the next transition, and no competing owner can mutate the journal. Add exact last-observation races from both `staged` and `metadata_ready`: pause after recovery observes missing/mismatch, let a second operation commit the same correct digest and touch the blob version, resume recovery, and assert the conditional corrupt transition loses, recovery retries from the caller's original state, re-observes ready bytes, and the correct blob is never marked corrupt.

Add lease/task races: unexpired SQL lease; expired lease with active `TaskFence`; an expired `ready` request lease after a fresh supervisor restart; commit held beyond expiry; recovered-stage commit held beyond expiry; renewal failure; duplicate fence registration; a task dead before fence registration; stale task reply; and a fresh supervisor restart where no old task survives. Assert recovery conditionally reclaims only the expired unfenced `ready` lease, and every no-row `:lost_lease`, `:timeout`, or `:effect_down` return leaves the journal, quota, blob state, and staging key untouched.

Add fairness fixtures with more than 50 entries in each stream. Keep the first page of tag repositories blocked by unexpected refs, the first page of file operations transiently unavailable, and the first page of terminal cleanups failing. Thread the returned cursors through at least three passes and assert a repository/operation above the original limit is attempted; after `next_cursor: nil`, assert the following pass wraps to the first page.

- [ ] Run recovery tests and confirm the recovery modules are absent:

```bash
mix test apps/forge_releases/test/recovery_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.Recovery` and `ForgeReleases.RecoveryScheduler`.

- [ ] Implement local-fence-aware claiming and repository-write reconciliation. The public `reconcile_repository/1` enters the shared `:tag` writer fence with a no-op final callback. The fence invokes registered reconcilers in priority order, so older Git and pull work finishes before `reconcile_repository_locked/3` claims release publication rows; this is not recursion because the registry calls the locked callback, not the public function:

```elixir
defmodule ForgeReleases.Recovery do
  @behaviour ForgeRepos.RepositoryWriteReconcilers

  import Ecto.Query

  alias ForgeReleases.{AssetOperation, ReleaseOperation, TaskFence}
  alias Fornacast.OperationLease

  @lease_seconds 30
  @terminal_release_states [:completed, :failed]
  @terminal_asset_states [:completed, :deleted, :failed]

  def claim_if_inactive(module, id, owner, now, lease_seconds \\ @lease_seconds) do
    if TaskFence.active?({module, id}) do
      :busy
    else
      OperationLease.claim(module, id, owner, now, lease_seconds)
    end
  end

  @impl true
  def reconcile_repository_locked(repository, repository_path, absolute_deadline) do
    owner = "release-tag-recovery:#{repository.id}:#{System.unique_integer([:positive])}"
    reconcile_next_tag(repository, repository_path, absolute_deadline, owner, 0)
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def reconcile_repository(repository) do
    case ForgeRepos.with_write_fence(repository, :tag, fn _path, _remaining_ms -> :ok end) do
      :ok ->
        :ok

      {:error, {:unavailable, _reason}} ->
        {:error, {:unavailable, :release_recovery}}
    end
  end
end
```

Immediately recheck `TaskFence.active?/1` before `OperationLease.claim/5`; if the fence becomes active between checks, the task registration occurred while the old owner still held an unexpired lease, so claim returns `:busy`. Process ascending IDs and stop with `{:error, :unavailable}` on an unresolved unexpected ref so later repository writes remain fenced.

- [ ] Implement the total tag-observation matrix using only direct refs and the persisted OIDs:

```elixir
defp classify_publication(path, operation, absolute_deadline) do
  with {:ok, current} <- observe_ref(path, operation.target_ref, absolute_deadline) do
    case {operation.state, operation.expected_oid, current} do
      {:prepared, nil, :absent} ->
        compensate_unpublished_release(operation, "effect_not_started")

      {:prepared, _expected, {:present, oid}} when oid == operation.proposed_oid ->
        operation
        |> retain_transition(state: :tag_ready)
        |> continue_publication()

      {state, _expected, {:present, oid}}
      when state in [:tag_ready, :metadata_ready] and oid == operation.proposed_oid ->
        continue_publication({:ok, operation})

      {_state, _expected, _observation} ->
        retain_unexpected_ref(operation)
    end
  end
end

defp observe_ref(path, target_ref, deadline) do
  remaining = deadline - System.monotonic_time(:millisecond)

  if remaining <= 0 do
    {:error, :unavailable}
  else
    case GitCore.exact_ref(path, target_ref, deadline_ms: remaining) do
      {:ok, nil} -> {:ok, :absent}
      {:ok, oid} -> {:ok, {:present, oid}}
      {:error, _reason} -> {:error, :unavailable}
    end
  end
end
```

For a recorded pre-existing tag (`expected_oid == proposed_oid`), a missing or different ref is unexpected. For `tag_ready` and `metadata_ready`, anything except `proposed_oid` is unexpected. Persist only sanitized `unexpected_ref`, emit one deduplicated safe alert, retain the nonterminal row, and return unavailable. Recovery never creates, moves, peels, or deletes a tag.

- [ ] Implement `staging`, `staged`, and `metadata_ready` upload recovery. `staging` is never inferred complete: clean the contained staging key, delete the invisible asset, release quota once, and fail. Every recovery `stat/1` plus full `verify/1` pair—including the initial staged check, metadata-ready check, and post-survivor second check—runs in renewing `MonitoredWork` and returns the newest owned row. For `staged`, verify ready CAS first; only confirmed absence may inspect the primary survivor:

```elixir
defp recover_staged(operation, absolute_deadline) do
  case monitored_ready_digest(operation, absolute_deadline) do
    {:ok, {:ready, observed_blob}, newest} ->
      persist_observed_ready_or_retry(newest, observed_blob, absolute_deadline)

    {:ok, {:absent, _observed_blob}, newest} ->
      recover_staged_survivor(newest, absolute_deadline)

    {:ok, {{:integrity_mismatch, failure}, observed_blob}, newest} ->
      corrupt_observed_or_retry(newest, observed_blob, failure, absolute_deadline)

    {:error, :storage_unavailable, newest} ->
      retain_for_retry(newest, :storage_unavailable)

    {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] ->
      {:error, :unavailable}
  end
end

defp monitored_ready_digest(operation, absolute_deadline) do
  with {:ok, observed_blob} <-
         BlobInventory.observe_for_recovery(operation.storage_key, operation.size),
       {:ok, timeout_ms} <- remaining_timeout(absolute_deadline, 120_000) do
    MonitoredWork.run(AssetOperation, operation, fn ->
      case ready_digest_effect(operation.storage_key, operation.size) do
        :ready -> {:ready, observed_blob}
        :absent -> {:absent, observed_blob}
        {:error, failure} when failure in [:missing, :size_mismatch, :digest_mismatch] ->
          {{:integrity_mismatch, failure}, observed_blob}

        {:error, :storage_unavailable} ->
          {:error, :storage_unavailable}
      end
    end,
      task_supervisor: ForgeReleases.WorkTaskSupervisor,
      lease_seconds: 60,
      renew_after_ms: 30_000,
      timeout_ms: timeout_ms
    )
  else
    {:error, :deadline} -> {:error, :timeout}
    {:error, _reason} -> {:error, :effect_down}
  end
end

defp ready_digest_effect(storage_key, expected_size) do
  with {:ok, %{size: ^expected_size}} <- storage_module().stat(storage_key),
       :ok <- storage_module().verify(storage_key) do
    :ready
  else
    {:error, :not_found} -> :absent
    {:ok, %{size: _other}} -> {:error, :size_mismatch}
    {:error, :integrity_mismatch} -> {:error, :digest_mismatch}
    {:error, _reason} -> {:error, :storage_unavailable}
  end
end

defp recover_metadata_ready(operation, absolute_deadline) do
  case monitored_ready_digest(operation, absolute_deadline) do
    {:ok, {:ready, observed_blob}, newest} ->
      complete_observed_ready_or_retry(newest, observed_blob, absolute_deadline)

    {:ok, {:absent, _observed_blob}, newest} ->
      confirm_metadata_missing(newest, absolute_deadline)

    {:ok, {{:integrity_mismatch, failure}, observed_blob}, newest} ->
      corrupt_observed_or_retry(newest, observed_blob, failure, absolute_deadline)

    {:error, :storage_unavailable, newest} ->
      retain_for_retry(newest, :storage_unavailable)

    {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] ->
      {:error, :unavailable}
  end
end

defp confirm_metadata_missing(operation, absolute_deadline) do
  case monitored_ready_digest(operation, absolute_deadline) do
    {:ok, {:ready, observed_blob}, newest} ->
      complete_observed_ready_or_retry(newest, observed_blob, absolute_deadline)

    {:ok, {:absent, observed_blob}, newest} ->
      corrupt_observed_or_retry(newest, observed_blob, :missing, absolute_deadline)

    {:ok, {{:integrity_mismatch, failure}, observed_blob}, newest} ->
      corrupt_observed_or_retry(newest, observed_blob, failure, absolute_deadline)

    {:error, :storage_unavailable, newest} -> retain_for_retry(newest, :storage_unavailable)
    {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] -> {:error, :unavailable}
  end
end

defp corrupt_observed_or_retry(operation, observed_blob, failure, absolute_deadline) do
  case BlobInventory.mark_corrupt_observed(observed_blob, operation.id, failure) do
    {:ok, _corrupt_blob} -> compensate_after_corrupt(operation, failure)
    :stale -> retry_observation(operation, absolute_deadline)
    :busy -> retain_for_retry(operation, :blob_busy)
    {:error, _reason} -> retain_for_retry(operation, :release_persistence)
  end
end

defp retry_observation(%AssetOperation{state: :staged} = operation, absolute_deadline),
  do: recover_staged(operation, absolute_deadline)

defp retry_observation(%AssetOperation{state: :metadata_ready} = operation, absolute_deadline),
  do: recover_metadata_ready(operation, absolute_deadline)
```

`remaining_timeout/2` returns `{:ok, min(cap_ms, absolute_deadline - monotonic_ms())}` only when positive. `observe_for_recovery/2` returns the exact blob row/version before the physical observation; if that row is `ready` with an expired lease and no active fence, it first calls `reclaim_expired_ready/2` and returns the refreshed version, while an active fence remains busy. `persist_observed_ready_or_retry/3` and `complete_observed_ready_or_retry/3` couple the version-qualified `pending|ready -> ready` touch and metadata transition in one transaction; `mark_corrupt_observed/3` compares state/version, rejects every remaining non-null blob lease, and rechecks that no different nonterminal operation references the digest before `pending|ready -> corrupt`. `compensate_after_corrupt/2` performs only invisible asset/quota/operation compensation and never attempts a second blob transition. Any stale CAS reloads and reruns the monitored observation. Thus a concurrent correct commit touches the version and wins instead of being overwritten by stale corruption. A transient effect failure remains nonterminal using the newest returned row. Confirmed missing is rechecked once, then conditionally marks the ledger corrupt, compensates the invisible asset/quota, and fails. Confirmed mismatch/verify failure uses the same conditional decision immediately. A no-row ownership failure returns unavailable and performs none of those mutations.

- [ ] Recover a survivor solely through Plan 1's opaque zero-copy contract. Never list or derive a path in this module. Pass only the persisted staging key, digest, and size, then commit the returned opaque `StagedRef` directly:

```elixir
defp recover_staged_survivor(operation, absolute_deadline) do
  with {:ok, timeout_ms} <- remaining_timeout(absolute_deadline, 1_800_000) do
    case MonitoredWork.run(AssetOperation, operation, fn ->
           recover_and_commit_stage(operation)
         end,
           task_supervisor: ForgeReleases.WorkTaskSupervisor,
           lease_seconds: 60,
           renew_after_ms: 30_000,
           timeout_ms: timeout_ms
         ) do
      {:ok, {:ready, metadata}, newest} ->
        persist_metadata_ready(newest, metadata)

      {:error, reason, newest}
      when reason in [:not_found, :invalid_source, :integrity_mismatch, :entity_too_large] ->
        recheck_after_survivor_failure(newest, absolute_deadline, reason)

      {:error, reason, newest} ->
        retain_for_retry(newest, reason)

      {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] ->
        {:error, :unavailable}
    end
  else
    {:error, :deadline} -> {:error, :unavailable}
  end
end

defp recheck_after_survivor_failure(operation, absolute_deadline, survivor_failure) do
  case monitored_ready_digest(operation, absolute_deadline) do
    {:ok, {:ready, observed_blob}, newest} ->
      persist_observed_ready_or_retry(newest, observed_blob, absolute_deadline)

    {:ok, {:absent, observed_blob}, newest} ->
      corrupt_observed_or_retry(newest, observed_blob, survivor_failure, absolute_deadline)

    {:ok, {{:integrity_mismatch, failure}, observed_blob}, newest} ->
      corrupt_observed_or_retry(newest, observed_blob, failure, absolute_deadline)

    {:error, :storage_unavailable, newest} -> retain_for_retry(newest, :storage_unavailable)
    {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] -> {:error, :unavailable}
  end
end
```

`recover_stage/3` is the Plan 1 gate that enforces exactly one direct regular entry, no symlink/nesting/multiple entries, expected size, and effective cap before calling ESS `LocalCAS.recover_stage/4`. ESS then hashes the file, confirms the same filesystem and stable device/inode, and returns a committable stage without copying it. After any missing/invalid survivor, recheck ready CAS exactly once before compensation to close a concurrent-commit race.

Recovery owns the staging key exclusively for the duration of this effect: the
claimed `AssetOperation` lease and `MonitoredWork` task fence must remain active
across `recover_stage/3`, commit, stat, and verify. Do not invoke recovery or
cleanup for the same staging key from a second request, task, or scheduler lane;
Plan 1 deliberately does not serialize concurrent directory mutation.

- [ ] Put in-place recovery, commit, stat, and verify inside the same `MonitoredWork` effect. It inherits the scheduler's absolute work deadline through the outer timeout and must not reset a fresh 30-minute budget inside the operation:

```elixir
defp recover_and_commit_stage(operation) do
  expected = %{
    sha256_digest: operation.sha256_digest,
    storage_key: operation.storage_key,
    size: operation.size
  }

  with {:ok, staged} <-
         storage_module().recover_stage(
           operation.staging_key,
           operation.sha256_digest,
           operation.size
         ),
       {:ok, ^expected} <- storage_module().commit(staged),
       {:ok, %{size: size}} when size == operation.size <-
         storage_module().stat(operation.storage_key),
       :ok <- storage_module().verify(operation.storage_key) do
    {:ready, expected}
  else
    {:ok, _unexpected} -> {:error, :integrity_mismatch}
    {:error, :ambiguous_commit} -> {:error, :ambiguous_commit}
    {:error, reason} -> {:error, reason}
  end
end
```

An ambiguous commit remains `staged`; the next pass first checks ready CAS, then safely recovers the same caller-owned stage again if it still exists. A mismatch fails closed. Lost ownership or task timeout leaves all durable state and the staging key for the next owner.

- [ ] Make terminal staging cleanup durable and retryable. Every bounded recovery pass additionally selects at most 50 terminal upload operations whose `staging_key` remains non-null, claims each only when `TaskFence` is inactive, runs cleanup in monitored work, and clears the persisted key only after it succeeds:

```elixir
defp cleanup_terminal_upload(operation, absolute_deadline) do
  with {:ok, timeout_ms} <- remaining_timeout(absolute_deadline, 30_000) do
    MonitoredWork.run(AssetOperation, operation, fn ->
      with :ok <- cleanup_key(operation.staging_key) do
        :clean
      end
    end,
      task_supervisor: ForgeReleases.WorkTaskSupervisor,
      lease_seconds: 30,
      renew_after_ms: 15_000,
      timeout_ms: timeout_ms
    )
    |> case do
      {:ok, :clean, owned} ->
        Fornacast.OperationLease.update_owned(
          AssetOperation,
          owned,
          staging_key: nil
        )

      {:error, _reason, owned} ->
        Fornacast.OperationLease.release(AssetOperation, owned)
        {:error, :cleanup_retry}

      {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] ->
        {:error, :unavailable}
    end
  else
    {:error, :deadline} -> {:error, :unavailable}
  end
end

defp cleanup_key(nil), do: :ok
defp cleanup_key(key), do: storage_module().cleanup_staging(key)
```

The query is indexed by `state, id` and includes `completed`, `failed`, and `deleted`. Cleanup failure increments safe retry telemetry and retains the logical key; it never rolls back terminal metadata. Add a fault test where cleanup fails after `completed`, then the next scheduler pass succeeds and clears the column. This bounded terminal scan is mandatory even when no nonterminal operation exists.

The terminal-cleanup claim and local task fence are also the exclusive ownership
proof for `cleanup_staging/1`. Keep them until Plan 1 has durably fsynced both the
staging-directory unlink and the `uploads` parent after `rmdir`; clear
`staging_key` only after that success. A retry after either injected directory
sync failure must retain the same logical key, reacquire exclusive ownership, and
complete idempotently.

- [ ] Implement idempotent asset/release deletion recovery. Asset `deleting` finishes the Task 6 metadata boundary. Release `deleting` admits/resumes at most 50 asset deletions; `assets_deleted` requires zero remaining assets before metadata deletion; `metadata_deleted` records the deduplicated audit and completes. Every pass preserves the tag and durable operation rows:

```elixir
defp recover_release_delete(operation) do
  case operation.state do
    :deleting ->
      with :ok <- resume_asset_deletes(operation.release_record_id, 50),
           false <- Repo.exists?(from asset in Asset, where: asset.release_id == ^operation.release_record_id),
           {:ok, operation} <- retain_transition(operation, state: :assets_deleted) do
        recover_release_delete(operation)
      else
        true -> :ok
        {:error, reason} -> {:error, reason}
      end

    :assets_deleted ->
      operation |> delete_release_metadata() |> continue_release_delete()

    :metadata_deleted ->
      complete_release_delete(operation, recovered_request_metadata(operation))
  end
end
```

Do not infer quota/count work from operation state alone; use the state-qualified metadata delete count so a repeated pass decrements only when it actually removes a row.

- [ ] Implement fair, immediate, bounded recovery dispatch whose GenServer callbacks perform no SQL or filesystem work. Keep independent cursors for tag repositories, nonterminal file operations, and terminal cleanup; every page reads at most 51 keys, attempts at most 50, advances past attempted failures, and wraps to `nil` only after the stream's end:

```elixir
defmodule ForgeReleases.RecoveryScheduler do
  use GenServer

  @interval_ms 30_000
  @work_budget_ms 1_800_000
  @outer_margin_ms 30_000
  @runtime_ms @work_budget_ms + @outer_margin_ms

  @initial_cursors %{
    tag_repository_id: nil,
    file_operation: nil,
    terminal_cleanup_id: nil
  }

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    {:ok,
     %{
       task: nil,
       runtime_timer: nil,
       cursors: @initial_cursors,
       monotonic_ms: Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
       task_supervisor: Keyword.get(options, :task_supervisor, ForgeReleases.RecoveryDispatchSupervisor),
       task_fun: Keyword.get(options, :task, &ForgeReleases.Recovery.reconcile_pending/2)
     }, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state), do: {:noreply, state |> schedule() |> start_task()}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> schedule() |> start_if_idle()}

  def handle_info({ref, {:ok, cursors}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil, cursors: cursors}}
  end

  def handle_info({ref, {:error, cursors}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil, cursors: cursors}}
  end

  def handle_info({ref, _unexpected}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info({:runtime_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_task(%{task: nil} = state) do
    deadline = state.monotonic_ms.() + @work_budget_ms
    task_fun = state.task_fun
    cursors = state.cursors

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        task_fun.(cursors, deadline)
      end)

    timer = Process.send_after(self(), {:runtime_timeout, task.ref}, @runtime_ms)
    %{state | task: task, runtime_timer: timer}
  end

  defp start_if_idle(state), do: if(state.task == nil, do: start_task(state), else: state)

  defp schedule(state) do
    Process.send_after(self(), :tick, @interval_ms)
    state
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer, async: false, info: false)
end
```

Implement the worker-side contract and cursor types explicitly:

```elixir
@type file_cursor ::
        nil
        | %{stream: :release_delete | :asset_nonterminal, id: non_neg_integer()}
@type cursors :: %{
        tag_repository_id: non_neg_integer() | nil,
        file_operation: file_cursor(),
        terminal_cleanup_id: non_neg_integer() | nil
      }

@spec reconcile_pending(cursors(), integer()) :: {:ok, cursors()} | {:error, cursors()}
def reconcile_pending(cursors, absolute_deadline) do
  {tag_cursor, tag_failures} =
    reconcile_tag_page(cursors.tag_repository_id, absolute_deadline, 50)

  {file_cursor, file_failures} =
    reconcile_file_page(cursors.file_operation, absolute_deadline, 50)

  {cleanup_cursor, cleanup_failures} =
    reconcile_terminal_cleanup_page(cursors.terminal_cleanup_id, absolute_deadline, 50)

  next = %{
    tag_repository_id: tag_cursor,
    file_operation: file_cursor,
    terminal_cleanup_id: cleanup_cursor
  }

  if tag_failures + file_failures + cleanup_failures == 0,
    do: {:ok, next},
    else: {:error, next}
end
```

Use portable grouped/union queries for the three cursor streams:

```elixir
defp tag_repository_keys(after_id, limit) do
  query =
    from operation in ReleaseOperation,
      where: operation.kind == :publish and operation.state not in [:completed, :failed],
      group_by: operation.repository_id,
      order_by: [asc: operation.repository_id],
      select: operation.repository_id

  query = if is_nil(after_id), do: query, else: where(query, [operation], operation.repository_id > ^after_id)
  query |> limit(^(limit + 1)) |> Repo.all()
end

defp file_operation_keys(cursor, limit) do
  release_deletes =
    from operation in ReleaseOperation,
      where:
        operation.kind == :delete and
          operation.state in [:deleting, :assets_deleted, :metadata_deleted],
      select: %{stream_rank: 0, id: operation.id}

  asset_operations =
    from operation in AssetOperation,
      where: operation.state in [:staging, :staged, :metadata_ready, :deleting],
      select: %{stream_rank: 1, id: operation.id}

  query = release_deletes |> union_all(^asset_operations) |> subquery()

  query =
    if is_nil(cursor) do
      query
    else
      rank = file_stream_rank(cursor.stream)

      where(
        query,
        [item],
        item.stream_rank > ^rank or (item.stream_rank == ^rank and item.id > ^cursor.id)
      )
    end

  query
  |> order_by([item], asc: item.stream_rank, asc: item.id)
  |> limit(^(limit + 1))
  |> Repo.all()
  |> Enum.map(fn %{stream_rank: rank, id: id} -> %{stream: file_stream(rank), id: id} end)
end

defp terminal_cleanup_keys(after_id, limit) do
  query =
    from operation in AssetOperation,
      where:
        operation.kind == :upload and operation.state in [:completed, :failed] and
          not is_nil(operation.staging_key),
      order_by: [asc: operation.id],
      select: operation.id

  query = if is_nil(after_id), do: query, else: where(query, [operation], operation.id > ^after_id)
  query |> limit(^(limit + 1)) |> Repo.all()
end
```

`run_cursor_page/5` takes the first `limit` keys, invokes the stream callback for each until the absolute deadline, records failures without halting on an item error, and returns the last actually attempted key when either an extra row or deadline remains; it returns `nil` only after the selected stream's end. The file rank mapping is fixed as `0 => :release_delete`, `1 => :asset_nonterminal`; reject every other value. These queries contain no adapter-specific locking or tuple comparison.

`reconcile_tag_page/3` selects distinct repository IDs strictly above the cursor in ascending order with `limit + 1`, calls public `reconcile_repository/1` for each attempted ID without preclaiming a release operation, and continues to later repositories after an unexpected ref or transient failure. Claiming still happens only inside the priority-300 locked callback, and one blocked repository still stops later writes for that same repository. `reconcile_file_page/3` pages one composite `{stream_rank, id}` key over release-delete and asset-nonterminal operations. `reconcile_terminal_cleanup_page/3` separately pages terminal upload IDs with retained staging keys. Each helper returns the last attempted key when more work remains and `nil` only after reaching its end; errors never reset it to the first row. Stop admitting new items when the shared absolute deadline has elapsed, and return the last attempted cursor so an unattempted key is not skipped.

Pass `absolute_deadline` into every file recovery and `cleanup_terminal_upload/2`. Derive each `MonitoredWork.timeout_ms` as `min(effect_cap_ms, absolute_deadline - monotonic_ms())`, require it to be positive, and never create an inner 30-minute deadline. Add a separate `ForgeReleases.RecoveryDispatchSupervisor` before the scheduler in `RecoverySupervisor`; keep `WorkTaskSupervisor` for linked monitored effects. The outer dispatch timeout is exactly 30 seconds larger than the work deadline, so every inner deadline is strictly below it and the coordinator has a fixed completion/cleanup margin. Killing the dispatch coordinator still kills its linked effect and the next pass retries after `TaskFence` observes `:DOWN`.

Add a clock-controlled near-deadline scheduler test: leave just enough work budget for one monitored terminal cleanup, hold it until immediately before the work deadline, then release it. Assert cleanup returns, clears the key with the newest row, and the scheduler consumes the correlated reply before its later outer timer. Also assert no new effect starts after the work deadline and the three cursors survive both partial-error replies and ordinary ticks.

- [ ] Run every recovery branch under deterministic seeds and commit:

```bash
mix format apps/forge_releases/lib/forge_releases/{recovery,recovery_scheduler,recovery_supervisor}.ex \
  apps/forge_releases/lib/forge_releases.ex \
  apps/forge_releases/test/recovery_test.exs
for seed in 0 1 2; do
  mix test apps/forge_releases/test/recovery_test.exs --max-cases 1 --seed "$seed" || exit 1
done
```

Expected: every run reports `0 failures`; every matrix branch is idempotent on a second pass, active local tasks fence expired rows until `:DOWN`, no recovery path constructs an ESS struct or path, and tags remain unchanged.

```bash
git add apps/forge_releases/lib/forge_releases/{recovery,recovery_scheduler,recovery_supervisor}.ex \
  apps/forge_releases/lib/forge_releases.ex apps/forge_releases/test/recovery_test.exs
git commit -m "feat(releases): recover every durable transition"
```

### Task 8: Reclaim unreachable blobs and audit retained tombstones safely

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/blob_gc.ex`
- Create: `apps/forge_releases/lib/forge_releases/blob_gc_scheduler.ex`
- Create: `apps/forge_releases/lib/forge_releases/integrity_audit.ex`
- Create: `apps/forge_releases/lib/forge_releases/storage_telemetry.ex`
- Create: `apps/forge_releases/lib/forge_releases/storage_telemetry_scheduler.ex`
- Create: `apps/forge_releases/test/blob_gc_test.exs`
- Create: `apps/forge_releases/test/integrity_audit_test.exs`
- Create: `apps/forge_releases/test/storage_telemetry_test.exs`
- Modify: `apps/forge_releases/test/asset_download_test.exs`
- Modify: `apps/forge_releases/lib/forge_releases/blob_inventory.ex`
- Modify: `apps/forge_releases/lib/forge_releases/recovery_supervisor.ex`
- Modify: `apps/forge_releases/lib/forge_releases/release_asset_blob.ex`

- [ ] Add failing BlobGC tests for candidate grace, orphan pending blobs, renewed references, shared content, expired ready-open lease reclamation, a worker paused after claim, lease expiry before `:DOWN`, same-digest attachment blocking, stale deleting selection, missing-byte success, and crash both before and after unlink:

```elixir
test "a due candidate is absent only after monitored delete", %{blob: blob} do
  now = frozen_now()
  candidate = mark_unreferenced_candidate!(blob, DateTime.add(now, -1, :second))

  assert {:ok, stats} = BlobGC.run_once(now: now, limit: 50)
  assert stats == %{
           examined: 1,
           candidates: 0,
           deleted: 1,
           retries: 0,
           failures: 0,
           next_due_cursor: nil
         }
  assert Repo.reload!(candidate).state == :absent
end

test "a claimed deletion blocks attachment until the task is down", context do
  claimed = claim_due_blob_and_pause!(context)
  operation = insert_staging_operation!()

  assert TaskFence.active?({ReleaseAssetBlob, claimed.id})
  assert {:error, :busy_deleting} =
           BlobInventory.attach(operation, claimed.sha256_digest, claimed.size,
             now: expired_now(),
             lease_seconds: 30
           )

  stop_paused_delete!()
  refute TaskFence.active?({ReleaseAssetBlob, claimed.id})
end
```

Assert unreferenced `ready` and orphaned `pending` rows become `candidate` with `gc_after = now + configured_grace`; referenced rows do not. A new attachment before deletion changes candidate to pending and invalidates the observed version. A missing LocalCAS key counts as successful deletion. Each crash case completes on a second pass.

For the stale-selection race, select a `deleting` row, let another worker finish `deleting -> absent`, attach the same digest through `absent -> pending -> ready`, then resume the stale worker. Assert `BlobInventory.claim_deleting/4` rejects the old state/version/reachability observation, `AssetStorage.delete/1` is never called, and the referenced ready bytes remain readable.

For an unreferenced `ready` row with an expired request-open lease and no local fence, assert candidate discovery selects it, `reclaim_expired_ready/2` conditionally clears/touches the exact version, and candidate marking proceeds. Repeat with an active `TaskFence` beyond lease expiry and assert the row remains `ready` and leased until exact `:DOWN`. If the old slow opener later returns a source after GC won the version, assert its release loses and it closes/fails rather than returning a handle.

Insert more than 50 due rows whose first 50 deletes fail transiently. Thread `next_due_cursor` into `due_after_id` on the next run and assert a higher-ID row is attempted before the failed low IDs are revisited. Assert each failed owned row receives a bounded `gc_after` retry time, the cursor wraps to `nil` at stream end, and a later wrapped run retries it. Add a clock-controlled near-deadline pass proving the last admitted delete finishes and returns before the scheduler's larger outer deadline, while no new delete starts after the GC work deadline.

- [ ] Add failing integrity tests for ready verification, missing/mismatch corruption, dry-run state/byte immutability, a paused verification that blocks GC and same-digest attachment until `:DOWN`, transient storage unavailability retaining `ready`, maintenance transition failure and lost-ownership handling, a physically present absent blob reported and marked corrupt without deleting bytes, all-state inventory, cursor pagination beyond 500 rows, bounded detail lists, telemetry shape, and absence of paths/digests/raw errors in telemetry. Add two linearization races: attachment changes an observed absent row before audit claim, and maintenance audit claims/detects same-size corruption before a future download open:

```elixir
test "dry run reports but does not delete a physically present absent blob", context do
  absent = insert_absent_blob_with_bytes!(context, "reappeared")

  assert {:ok,
          %{
            checked: 1,
            corrupt: 0,
            absent_reappeared: 1,
            failures: 0
          }} = IntegrityAudit.run(mode: :dry_run, limit: 50)

  assert {:ok, _metadata} = AssetStorage.stat(absent.sha256_digest)
  assert Repo.reload!(absent).state == :absent
end

test "maintenance marks present bytes behind an absent tombstone corrupt", context do
  absent = insert_absent_blob_with_bytes!(context, "reappeared")

  assert {:ok, %{corrupt: 1, absent_reappeared: 1}} =
           IntegrityAudit.run(mode: :maintenance, limit: 50)

  assert {:ok, _metadata} = AssetStorage.stat(absent.sha256_digest)
  assert Repo.reload!(absent).state == :corrupt
end

test "an absent observation changed by attachment is skipped without a false report", context do
  observed = insert_absent_blob_with_bytes!(context, "raced")
  pause_before_audit_claim!(observed.id)
  task = Task.async(fn -> IntegrityAudit.run(mode: :dry_run, limit: 50) end)
  assert_receive :before_audit_claim
  attach_and_commit_same_digest!(context, observed)
  resume_audit_claim!()

  assert {:ok, %{absent_reappeared: 0, failures: 0}} = Task.await(task)
  assert Repo.get!(ReleaseAssetBlob, observed.id).state == :ready
end
```

Insert 1,005 mixed-state rows with actionable `ready`/`absent` entries above IDs 500 and 1,000. Starting with `after_id: nil`, thread each returned `next_cursor` into the next call until it is `nil`; assert every row appears exactly once in `blobs`, every actionable high-ID row is checked, no page has more than `limit` rows, and a new call with `after_id: nil` wraps to the first page. In the download race, pause maintenance after its observed-version claim, assert `open_asset/3` fails before `AssetStorage.open/3`, resume detection, and assert every future open remains unavailable when the row becomes `corrupt`; an already-open descriptor from a claim that linearized first remains governed by Task 6's handle contract.

- [ ] Run both suites and confirm GC/audit modules are absent:

```bash
mix test apps/forge_releases/test/blob_gc_test.exs \
  apps/forge_releases/test/integrity_audit_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.BlobGC`, `BlobGCScheduler`, and `IntegrityAudit`.

- [ ] Implement cursor-fair bounded candidate marking and deletion. `run_once/1` accepts `now:`, `limit:`, `due_after_id:`, and an internal absolute `deadline_ms:`; production defaults to current UTC, a limit of 50, a nil cursor, and a 25-second work budget. Validate/clamp `limit` to `1..50` and return the next due cursor:

```elixir
defmodule ForgeReleases.BlobGC do
  import Ecto.Query

  alias ForgeReleases.{BlobInventory, MonitoredWork, ReleaseAssetBlob, TaskFence}
  alias Fornacast.{OperationLease, Repo}

  @default_limit 50
  @work_budget_ms 25_000

  @spec run_once(keyword()) ::
          {:ok,
           %{
             examined: non_neg_integer(),
             candidates: non_neg_integer(),
             deleted: non_neg_integer(),
             retries: non_neg_integer(),
             failures: non_neg_integer(),
             next_due_cursor: non_neg_integer() | nil
           }}
          | {:error, {:unavailable, atom()}}
  def run_once(options \\ []) do
    if ForgeReleases.AssetStorage.ready?() do
      now = Keyword.get(options, :now, DateTime.utc_now() |> DateTime.truncate(:second))
      limit = options |> Keyword.get(:limit, @default_limit) |> min(@default_limit) |> max(1)
      due_after_id = Keyword.get(options, :due_after_id)
      deadline_ms =
        Keyword.get_lazy(options, :deadline_ms, fn ->
          System.monotonic_time(:millisecond) + @work_budget_ms
        end)
      grace = Fornacast.Config.release_asset_gc_grace_seconds()

      deletion_stats = delete_due(now, limit, due_after_id, deadline_ms)
      candidates =
        if System.monotonic_time(:millisecond) < deadline_ms,
          do: BlobInventory.unreferenced_candidates(now, limit),
          else: []

      {candidate_examined, marked} =
        Enum.reduce_while(candidates, {0, 0}, fn blob, {examined, marked} ->
          if System.monotonic_time(:millisecond) >= deadline_ms do
            {:halt, {examined, marked}}
          else
            candidate =
              if blob.state == :ready and not is_nil(blob.lease_owner),
                do: BlobInventory.reclaim_expired_ready(blob, now),
                else: {:ok, blob}

            increment =
              case candidate do
                {:ok, current} ->
                  if System.monotonic_time(:millisecond) >= deadline_ms do
                    0
                  else
                    if BlobInventory.mark_candidate(
                         current,
                         DateTime.add(now, grace, :second)
                       ) == :ok,
                      do: 1,
                      else: 0
                  end

                :busy ->
                  0
              end

            {:cont, {examined + 1, marked + increment}}
          end
        end)

      {:ok,
       %{
         examined: candidate_examined + deletion_stats.examined,
         candidates: marked,
         deleted: deletion_stats.deleted,
         retries: deletion_stats.retries,
         failures: deletion_stats.failures,
         next_due_cursor: deletion_stats.next_cursor
       }}
    else
      {:error, {:unavailable, :asset_storage}}
    end
  end
end
```

Implement the candidate selector with reachability predicates in SQL so referenced rows at the front cannot starve later unreferenced rows:

```elixir
def unreferenced_candidates(now, limit)
    when is_struct(now, DateTime) and is_integer(limit) and limit in 1..50 do
  asset_reference =
    from asset in Asset,
      where:
        asset.storage_key == parent_as(:blob).sha256_digest and
          asset.state in ^@asset_references,
      select: 1

  operation_reference =
    from operation in AssetOperation,
      where:
        operation.sha256_digest == parent_as(:blob).sha256_digest and
          operation.state in ^@operation_references,
      select: 1

  ReleaseAssetBlob
  |> from(as: :blob)
  |> where(
    [blob],
    ((blob.state == :ready and
        (is_nil(blob.lease_owner) or
           (not is_nil(blob.lease_expires_at) and blob.lease_expires_at <= ^now))) or
       (blob.state == :pending and is_nil(blob.lease_owner))) and
      not exists(subquery(asset_reference)) and not exists(subquery(operation_reference))
  )
  |> order_by([blob], asc: blob.id)
  |> limit(^limit)
  |> Repo.all()
end
```

Implement the due-page query and cursor advancement in production code, not only in the scheduler:

```elixir
defp delete_due(now, limit, after_id, deadline_ms) do
  query =
    from blob in ReleaseAssetBlob,
      where:
        (blob.state == :candidate and blob.gc_after <= ^now and is_nil(blob.lease_owner)) or
          (blob.state == :deleting and
             (is_nil(blob.gc_after) or blob.gc_after <= ^now) and
             (is_nil(blob.lease_owner) or blob.lease_expires_at <= ^now)),
      order_by: [asc: blob.id]

  query = if is_nil(after_id), do: query, else: where(query, [blob], blob.id > ^after_id)
  rows = query |> limit(^(limit + 1)) |> Repo.all()
  page = Enum.take(rows, limit)

  {stats, last_attempted, completed_page?} =
    Enum.reduce_while(page, {empty_delete_stats(), after_id, true}, fn blob,
                                                                      {stats, last, _} ->
      if System.monotonic_time(:millisecond) >= deadline_ms do
        {:halt, {stats, last, false}}
      else
        outcome = claim_and_delete_due(blob, now, deadline_ms)
        {:cont, {record_delete_outcome(stats, outcome), blob.id, true}}
      end
    end)

  next_cursor =
    cond do
      not completed_page? -> last_attempted
      length(rows) > limit -> last_attempted
      true -> nil
    end

  Map.put(stats, :next_cursor, next_cursor)
end

defp empty_delete_stats do
  %{examined: 0, deleted: 0, retries: 0, failures: 0}
end

defp record_delete_outcome(stats, {:ok, %ReleaseAssetBlob{state: :absent}}) do
  stats |> Map.update!(:examined, &(&1 + 1)) |> Map.update!(:deleted, &(&1 + 1))
end

defp record_delete_outcome(stats, outcome)
     when outcome in [:retry, {:error, :retry}, {:error, :deadline}, {:error, :lost_lease},
                      {:error, :timeout}, {:error, :effect_down}] do
  stats |> Map.update!(:examined, &(&1 + 1)) |> Map.update!(:retries, &(&1 + 1))
end

defp record_delete_outcome(stats, _unexpected) do
  stats |> Map.update!(:examined, &(&1 + 1)) |> Map.update!(:failures, &(&1 + 1))
end

defp claim_and_delete_due(blob, now, deadline_ms) do
  if TaskFence.active?({ReleaseAssetBlob, blob.id}) do
    :retry
  else
    owner = "blob-gc:#{blob.id}:#{System.unique_integer([:positive])}"

    claim =
      case blob.state do
        :candidate -> BlobInventory.claim_deletion(blob.id, blob.lock_version, owner, now, 15)
        :deleting -> BlobInventory.claim_deleting(blob, owner, now, 15)
      end

    case claim do
      {:ok, owned} -> delete_claimed(owned, now, deadline_ms)
      :busy -> :retry
    end
  end
end
```

The reducer tracks the prior attempted cursor explicitly, so a deadline before the first row returns the input cursor unchanged and never skips that row. `record_delete_outcome/2` increments `examined` only for an attempted row and classifies success/retry/failure without throwing.

`delete_due/4` queries at most `limit + 1` rows strictly above `due_after_id`, combining due candidates and expired/unowned `deleting` rows ordered by ID. It attempts at most `limit` and stops admitting work at `deadline_ms`; its cursor is the last attempted ID when more rows remain and `nil` only at stream end. A scheduler threads the cursor so retrying low IDs cannot starve later due rows. Candidate discovery remains an independent `limit`-bounded query after deletion, so a run may examine at most `2 * limit` attempted rows. Candidate claims use `BlobInventory.claim_deletion/5`; deleting recovery uses the selected struct with `BlobInventory.claim_deleting/4`, never generic `OperationLease.claim/5`, and only after `TaskFence.active?({ReleaseAssetBlob, id})` is false. The second claim must atomically recheck `state == :deleting`, observed `lock_version`, retry time, lease expiry, and both reachability predicates before any filesystem effect.

- [ ] Run physical deletion in `MonitoredWork`, retain ownership through completion, and treat a durably confirmed missing blob as success. ESS v0.6.4 syncs the containing directory after both unlink and already-missing retries; any directory-sync error keeps the row `deleting` for another idempotent attempt:

```elixir
defp delete_claimed(%ReleaseAssetBlob{} = owned, now, absolute_deadline) do
  remaining = absolute_deadline - System.monotonic_time(:millisecond)

  if remaining <= 0 do
    _deferred = BlobInventory.defer_deletion(owned, DateTime.add(now, 30, :second))
    {:error, :deadline}
  else
    MonitoredWork.run(ReleaseAssetBlob, owned, fn ->
      case storage_module().delete(owned.sha256_digest) do
        :ok -> :deleted
        {:error, :not_found} -> :deleted
        {:error, _reason} -> {:error, :unavailable}
      end
    end,
      task_supervisor: ForgeReleases.WorkTaskSupervisor,
      lease_seconds: 15,
      renew_after_ms: 5_000,
      timeout_ms: min(5_000, remaining)
    )
    |> case do
      {:ok, :deleted, newest} ->
        OperationLease.update_owned(ReleaseAssetBlob, newest,
          state: :absent,
          gc_after: nil,
          integrity_failure: nil
        )

      {:error, _reason, newest} ->
        BlobInventory.defer_deletion(newest, DateTime.add(now, 30, :second))
        {:error, :retry}

      {:error, reason} when reason in [:lost_lease, :timeout, :effect_down] ->
        {:error, reason}
    end
  end
end
```

`BlobInventory.defer_deletion/2` conditionally keeps the newest owned row `deleting`, stores the supplied `gc_after` as its retry time, releases the lease, and increments the version. Call it immediately if the shared deadline expires after claim but before the delete starts; do not leave that known-owned lease waiting for expiry. A no-row ownership result cannot call it. Candidate marking rechecks the same absolute deadline before every row, so a large candidate page cannot consume the five-second outer margin. The blob schema's lease changeset permits `deleting -> absent` after durable delete and `absent -> corrupt` only for a claimed maintenance integrity finding; candidate reactivation remains available only through `BlobInventory.attach/4`, and there is no transition out of `corrupt`. Attachment remains blocked by every non-ready lease and every unexpired or locally fenced ready lease. Only the observed-version `reclaim_expired_ready/2` path may clear an expired `ready` lease with no active fence before retrying attachment.

- [ ] Define the exact cursor-based operational audit API consumed by Plan 3. Reject unknown/duplicate options; default to dry run, a limit of 50, and `after_id: nil`; accept a maximum limit of 500. A caller must thread non-null `next_cursor` values until `nil`, then start the next full rotation with `after_id: nil`:

```elixir
defmodule ForgeReleases.IntegrityAudit do
  import Ecto.Query

  alias ForgeReleases.{BlobInventory, MonitoredWork, ReleaseAssetBlob, TaskFence}
  alias Fornacast.{OperationLease, Repo}

  @type result :: %{
          checked: non_neg_integer(),
          corrupt: non_neg_integer(),
          absent_reappeared: non_neg_integer(),
          failures: non_neg_integer(),
          next_cursor: non_neg_integer() | nil,
          blob_states: %{
            absent: non_neg_integer(),
            pending: non_neg_integer(),
            ready: non_neg_integer(),
            candidate: non_neg_integer(),
            deleting: non_neg_integer(),
            corrupt: non_neg_integer()
          },
          blobs: [%{digest: String.t(), size: non_neg_integer(), state: atom()}],
          integrity_failures: [%{digest: String.t(), failure: atom()}]
        }

  @spec run(keyword()) ::
          {:ok, result()} | {:error, {:unavailable, atom()}}
  def run(options \\ []) do
    with {:ok, mode, limit, after_id} <- validate_options(options),
         true <- ForgeReleases.AssetStorage.ready?() do
      page_query =
        ReleaseAssetBlob
        |> order_by([blob], asc: blob.id)

      page_query =
        if is_nil(after_id),
          do: page_query,
          else: where(page_query, [blob], blob.id > ^after_id)

      rows =
        page_query
        |> limit(^(limit + 1))
        |> Repo.all()

      page = Enum.take(rows, limit)
      next_cursor = if length(rows) > limit, do: List.last(page).id, else: nil

      blobs =
        Enum.map(page, fn blob ->
          %{digest: blob.sha256_digest, size: blob.size, state: blob.state}
        end)

      result =
        Enum.reduce(
          page,
          empty_result(blob_state_counts(), blobs, next_cursor),
          &audit_blob(&2, &1, mode)
        )

      :telemetry.execute(
        [:fornacast, :release_assets, :integrity_audit, :stop],
        Map.take(result, [
          :checked,
          :corrupt,
          :absent_reappeared,
          :failures
        ]),
        %{mode: mode}
      )

      {:ok, result}
    else
      false -> {:error, {:unavailable, :asset_storage}}
      {:error, :invalid_options} -> {:error, {:unavailable, :invalid_audit_options}}
    end
  end

  defp validate_options(options) do
    if Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
         Enum.all?(Keyword.keys(options), &(&1 in [:mode, :limit, :after_id])) do
      mode = Keyword.get(options, :mode, :dry_run)
      limit = Keyword.get(options, :limit, 50)
      after_id = Keyword.get(options, :after_id)

      if mode in [:dry_run, :maintenance] and is_integer(limit) and limit in 1..500 and
           (is_nil(after_id) or (is_integer(after_id) and after_id >= 0)),
        do: {:ok, mode, limit, after_id},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp empty_result(blob_states, blobs, next_cursor) do
    %{
      checked: 0,
      corrupt: 0,
      absent_reappeared: 0,
      failures: 0,
      next_cursor: next_cursor,
      blob_states: blob_states,
      blobs: blobs,
      integrity_failures: []
    }
  end

  defp blob_state_counts do
    base = %{absent: 0, pending: 0, ready: 0, candidate: 0, deleting: 0, corrupt: 0}

    ReleaseAssetBlob
    |> group_by([blob], blob.state)
    |> select([blob], {blob.state, count(blob.id)})
    |> Repo.all()
    |> Enum.reduce(base, fn {state, count}, counts -> Map.put(counts, state, count) end)
  end
end
```

This exact function name, option vocabulary, return shape, and error algebra are the Plan 3 operational contract. The page query reads at most `limit + 1` rows across every blob state, so the `blobs` and `integrity_failures` details are bounded by `limit`, ordered by blob ID, and contain only digest/size/state or a sanitized failure atom. Non-`ready`/`absent` page rows are inventory detail only. The separate grouped count returns at most the six declared states. Allowed failure atoms are `:missing`, `:size_mismatch`, `:digest_mismatch`, `:absent_reappeared`, and `:storage_unavailable`; never include a raw reason. Do not add a second `StorageAudit` API.

- [ ] Implement ready verification and absent-tombstone handling. Both paths conditionally claim the exact observed state/version only when `TaskFence` is inactive and run all storage observations/effects inside one `MonitoredWork`; this blocks candidate marking, deletion, attachment, and new download opens while bytes are being verified. Dry run may advance lease/lock-version coordination metadata but never changes blob state, integrity failure, or bytes. A state/version race, busy local fence, or no-row ownership failure skips the row without incrementing `checked`, `failures`, or any finding:

```elixir
defp audit_blob(result, %ReleaseAssetBlob{state: :ready} = blob, mode) do
  if TaskFence.active?({ReleaseAssetBlob, blob.id}) do
    result
  else
    case BlobInventory.claim_observed(blob, audit_owner(), DateTime.utc_now(), 60) do
      {:ok, %{state: :ready} = owned} ->
        verify_claimed_ready(owned, mode, result)

      :stale -> result
      :busy -> result
      {:error, _reason} -> increment(result, :failures)
    end
  end
end

defp verify_claimed_ready(owned, mode, result) do
  MonitoredWork.run(ReleaseAssetBlob, owned, fn ->
    case storage_module().stat(owned.sha256_digest) do
      {:ok, %{size: size}} when size == owned.size ->
        case storage_module().verify(owned.sha256_digest) do
          :ok -> :verified
          {:error, :integrity_mismatch} -> {:error, :digest_mismatch}
          {:error, :not_found} -> {:error, :missing}
          {:error, _reason} -> {:error, :storage_unavailable}
        end

      {:ok, %{size: _other}} ->
        {:error, :size_mismatch}

      {:error, :not_found} ->
        {:error, :missing}

      {:error, _reason} ->
        {:error, :storage_unavailable}
    end
  end,
    task_supervisor: ForgeReleases.WorkTaskSupervisor,
    lease_seconds: 60,
    renew_after_ms: 30_000,
    timeout_ms: 120_000
  )
  |> finish_ready_verification(mode, result)
end

defp finish_ready_verification({:ok, :verified, newest}, _mode, result) do
  release_and_update_result(newest, result, &increment(&1, :checked))
end

defp finish_ready_verification({:error, :storage_unavailable, newest}, _mode, result) do
  release_and_update_result(newest, result, fn released ->
    released
    |> increment(:checked)
    |> increment(:failures)
    |> record_integrity_failure(newest.sha256_digest, :storage_unavailable)
  end)
end

defp finish_ready_verification({:error, failure, newest}, :dry_run, result)
     when failure in [:missing, :size_mismatch, :digest_mismatch] do
  release_and_update_result(newest, result, fn released ->
    released
    |> increment(:checked)
    |> increment(:corrupt)
    |> record_integrity_failure(newest.sha256_digest, failure)
  end)
end

defp finish_ready_verification({:error, failure, newest}, :maintenance, result)
     when failure in [:missing, :size_mismatch, :digest_mismatch] do
  case OperationLease.update_owned(ReleaseAssetBlob, newest,
         state: :corrupt,
         integrity_failure: Atom.to_string(failure)
       ) do
    {:ok, corrupt} ->
      result
      |> increment(:checked)
      |> increment(:corrupt)
      |> record_integrity_failure(corrupt.sha256_digest, failure)

    {:error, :lost_lease} ->
      result

    {:error, _reason} ->
      finish_audit_persistence_failure(result, newest)
  end
end

defp finish_ready_verification({:error, ownership_reason}, _mode, result)
     when ownership_reason in [:lost_lease, :timeout, :effect_down],
     do: result

defp audit_blob(result, %ReleaseAssetBlob{state: :absent} = blob, mode) do
  if TaskFence.active?({ReleaseAssetBlob, blob.id}) do
    result
  else
    case BlobInventory.claim_observed(blob, audit_owner(), DateTime.utc_now(), 60) do
      {:ok, %{state: :absent} = owned} ->
        MonitoredWork.run(ReleaseAssetBlob, owned, fn ->
          case storage_module().stat(owned.sha256_digest) do
            {:error, :not_found} ->
              :absent_clean

            {:ok, _metadata} ->
              {:error, :absent_reappeared}

            {:error, _reason} ->
              {:error, :storage_unavailable}
          end
        end,
          task_supervisor: ForgeReleases.WorkTaskSupervisor,
          lease_seconds: 60,
          renew_after_ms: 30_000,
          timeout_ms: 120_000
        )
        |> finish_absent_audit(mode, result)

      :stale -> result
      :busy -> result
      {:error, _reason} -> increment(result, :failures)
    end
  end
end

defp audit_blob(result, %ReleaseAssetBlob{}, _mode), do: result

defp finish_absent_audit({:ok, :absent_clean, newest}, _mode, result) do
  release_and_update_result(newest, result, &increment(&1, :checked))
end

defp finish_absent_audit({:error, :absent_reappeared, newest}, :dry_run, result) do
  release_and_update_result(newest, result, fn released ->
    released
    |> increment(:checked)
    |> increment(:absent_reappeared)
    |> record_integrity_failure(newest.sha256_digest, :absent_reappeared)
  end)
end

defp finish_absent_audit({:error, :absent_reappeared, newest}, :maintenance, result) do
  case OperationLease.update_owned(ReleaseAssetBlob, newest,
         state: :corrupt,
         integrity_failure: "absent_reappeared"
       ) do
    {:ok, corrupt} ->
      result
      |> increment(:checked)
      |> increment(:corrupt)
      |> increment(:absent_reappeared)
      |> record_integrity_failure(corrupt.sha256_digest, :absent_reappeared)

    {:error, :lost_lease} ->
      result

    {:error, _reason} ->
      finish_absent_audit_persistence_failure(result, newest)
  end
end

defp finish_absent_audit({:error, :storage_unavailable, newest}, _mode, result) do
  release_and_update_result(newest, result, fn released ->
    released
    |> increment(:checked)
    |> increment(:failures)
    |> record_integrity_failure(newest.sha256_digest, :storage_unavailable)
  end)
end

defp finish_absent_audit({:error, ownership_reason}, _mode, result)
     when ownership_reason in [:lost_lease, :timeout, :effect_down],
     do: result

defp release_and_update_result(newest, result, update) when is_function(update, 1) do
  case OperationLease.release(ReleaseAssetBlob, newest) do
    :ok -> update.(result)
    {:error, :lost_lease} -> result
  end
end

defp finish_audit_persistence_failure(result, newest) do
  case OperationLease.release(ReleaseAssetBlob, newest) do
    :ok ->
      result
      |> increment(:checked)
      |> increment(:failures)
      |> record_integrity_failure(newest.sha256_digest, :storage_unavailable)

    {:error, :lost_lease} ->
      result
  end
end

defp finish_absent_audit_persistence_failure(result, newest) do
  case OperationLease.release(ReleaseAssetBlob, newest) do
    :ok ->
      result
      |> increment(:checked)
      |> increment(:absent_reappeared)
      |> increment(:failures)
      |> record_integrity_failure(newest.sha256_digest, :storage_unavailable)

    {:error, :lost_lease} ->
      result
  end
end

defp record_integrity_failure(result, digest, failure)
     when failure in [
            :missing,
            :size_mismatch,
            :digest_mismatch,
            :absent_reappeared,
            :storage_unavailable
          ] do
  entry = %{digest: digest, failure: failure}
  %{result | integrity_failures: result.integrity_failures ++ [entry]}
end

defp increment(result, key), do: Map.update!(result, key, &(&1 + 1))
```

`BlobInventory.claim_observed/4` compares the page struct's state and `lock_version`, requires no active `TaskFence`, and atomically sets the audit owner when the observed lease is null or expired. This lets a fresh BEAM reclaim an expired `ready` request lease without an unowned gap; any stale opener subsequently loses release ownership and closes/fails. For absent rows, `stat/1` happens under that same renewing lease and fence; an attachment that wins before the claim changes the version produces no false `absent_reappeared` report. Timeout/lost ownership does not clear another owner's lease or change state. A physically present absent blob is an integrity failure: dry run reports it without mutation, while maintenance atomically marks the ledger row `corrupt` and leaves the bytes untouched for operator recovery. Ready missing/size/verify disagreement likewise becomes `corrupt` only in maintenance; no mode deletes, repairs, or promotes bytes.

- [ ] Add failing `StorageTelemetry` tests for CAS/staging byte and inode pressure, all nonterminal upload/delete operation states, all six blob states, storage/persistence unavailability, bounded aggregate query results, the exact callable return shape, and telemetry redaction:

```elixir
test "snapshot reports fixed aggregate capacity operation and blob fields", context do
  install_capacity!(%{
    cas: %{
      bytes: %{total: 1_000, available: 250},
      inodes: %{total: 100, available: 40}
    },
    staging: %{
      bytes: %{total: 2_000, available: 1_500},
      inodes: %{total: 200, available: 180}
    }
  })

  insert_every_nonterminal_operation!(context)
  insert_every_blob_state!(context)

  assert {:ok,
          %{
            capacity: %{
              cas: %{
                bytes: %{
                  total: 1_000,
                  available: 250,
                  used: 750,
                  pressure_basis_points: 7_500,
                  known: true
                },
                inodes: %{
                  total: 100,
                  available: 40,
                  used: 60,
                  pressure_basis_points: 6_000,
                  known: true
                }
              },
              staging: %{
                bytes: %{
                  total: 2_000,
                  available: 1_500,
                  used: 500,
                  pressure_basis_points: 2_500,
                  known: true
                },
                inodes: %{
                  total: 200,
                  available: 180,
                  used: 20,
                  pressure_basis_points: 1_000,
                  known: true
                }
              }
            },
            operations: %{upload_nonterminal: 3, delete_nonterminal: 4},
            blob_states: %{
              absent: 1,
              pending: 1,
              ready: 1,
              candidate: 1,
              deleting: 1,
              corrupt: 1
            }
          }} = StorageTelemetry.snapshot()
end

test "zero inode totals are explicitly unknown", context do
  install_capacity!(%{
    cas: %{
      bytes: %{total: 1_000, available: 250},
      inodes: %{total: 0, available: 0}
    },
    staging: %{
      bytes: %{total: 2_000, available: 1_500},
      inodes: %{total: 0, available: 0}
    }
  })

  assert {:ok, snapshot} = StorageTelemetry.snapshot()

  assert snapshot.capacity.cas.inodes == %{
           total: 0,
           available: 0,
           used: 0,
           pressure_basis_points: 0,
           known: false
         }

  assert snapshot.capacity.staging.inodes.known == false
  assert snapshot.capacity.cas.bytes.known == true
  assert snapshot.capacity.staging.bytes.known == true
end
```

Add a supported-host case where inode totals are `0`: assert the normalized inode dimensions are `%{total: 0, available: 0, used: 0, pressure_basis_points: 0, known: false}` rather than presenting zero as known healthy pressure. Byte dimensions must be `known: true`. The telemetry-handler test calls `emit/0`, recursively inspects measurement keys/metadata, and rejects values or keys containing `path`, `root`, `mount`, `digest`, `key`, `secret`, `token`, raw reason text, an ESS struct, or a credential. Assert only integer aggregate measurements—including fixed `*_known` values `0 | 1`—and `%{result: :ok}` metadata are emitted. Instrument the SQL sandbox and assert a snapshot performs exactly three scalar operation-count queries plus one six-row-maximum grouped blob-state query; no detail row or unbounded list is returned.

- [ ] Run the new test and confirm the callable module is absent:

```bash
mix test apps/forge_releases/test/storage_telemetry_test.exs --max-cases 1 --seed 0
```

Expected red result: undefined `ForgeReleases.StorageTelemetry` and `StorageTelemetryScheduler`.

- [ ] Implement the exact aggregate operational contract. `snapshot/0` returns only normalized capacity, two operation counts, and a total for every declared blob state; `emit/0` returns that same tagged result after emitting one flat aggregate event:

```elixir
defmodule ForgeReleases.StorageTelemetry do
  import Ecto.Query

  alias ForgeReleases.{AssetOperation, ReleaseAssetBlob, ReleaseOperation}
  alias Fornacast.Repo

  @blob_states [:absent, :pending, :ready, :candidate, :deleting, :corrupt]
  @upload_states [:staging, :staged, :metadata_ready]
  @asset_delete_states [:deleting]
  @release_delete_states [:deleting, :assets_deleted, :metadata_deleted]

  @type dimension :: %{
          total: non_neg_integer(),
          available: non_neg_integer(),
          used: non_neg_integer(),
          pressure_basis_points: 0..10_000,
          known: boolean()
        }
  @type snapshot :: %{
          capacity: %{
            cas: %{bytes: dimension(), inodes: dimension()},
            staging: %{bytes: dimension(), inodes: dimension()}
          },
          operations: %{upload_nonterminal: non_neg_integer(), delete_nonterminal: non_neg_integer()},
          blob_states: %{
            absent: non_neg_integer(),
            pending: non_neg_integer(),
            ready: non_neg_integer(),
            candidate: non_neg_integer(),
            deleting: non_neg_integer(),
            corrupt: non_neg_integer()
          }
        }

  @spec snapshot() ::
          {:ok, snapshot()}
          | {:error, {:unavailable, :asset_storage | :release_persistence}}
  def snapshot do
    with {:ok, capacity} <- ForgeReleases.AssetStorage.capacity() do
      {:ok,
       %{
         capacity: add_pressure(capacity),
         operations: operation_counts(),
         blob_states: blob_state_counts()
       }}
    else
      {:error, _reason} -> {:error, {:unavailable, :asset_storage}}
    end
  rescue
    _error -> {:error, {:unavailable, :release_persistence}}
  catch
    _kind, _reason -> {:error, {:unavailable, :release_persistence}}
  end

  @spec emit() ::
          {:ok, snapshot()}
          | {:error, {:unavailable, :asset_storage | :release_persistence}}
  def emit do
    case snapshot() do
      {:ok, snapshot} = result ->
        :telemetry.execute(
          [:fornacast, :release_assets, :storage, :snapshot],
          measurements(snapshot),
          %{result: :ok}
        )

        result

      {:error, _reason} = error ->
        :telemetry.execute(
          [:fornacast, :release_assets, :storage, :error],
          %{failures: 1},
          %{result: :unavailable}
        )

        error
    end
  end

  defp operation_counts do
    uploads =
      Repo.aggregate(
        from(operation in AssetOperation,
          where: operation.kind == :upload and operation.state in ^@upload_states
        ),
        :count,
        :id
      )

    asset_deletes =
      Repo.aggregate(
        from(operation in AssetOperation,
          where: operation.kind == :delete and operation.state in ^@asset_delete_states
        ),
        :count,
        :id
      )

    release_deletes =
      Repo.aggregate(
        from(operation in ReleaseOperation,
          where: operation.kind == :delete and operation.state in ^@release_delete_states
        ),
        :count,
        :id
      )

    %{upload_nonterminal: uploads, delete_nonterminal: asset_deletes + release_deletes}
  end

  defp blob_state_counts do
    base = Map.new(@blob_states, &{&1, 0})

    ReleaseAssetBlob
    |> group_by([blob], blob.state)
    |> select([blob], {blob.state, count(blob.id)})
    |> Repo.all()
    |> Enum.reduce(base, fn {state, count}, counts -> Map.put(counts, state, count) end)
  end

  defp add_pressure(capacity) do
    Map.new(capacity, fn {area, dimensions} ->
      {area, Map.new(dimensions, fn {name, values} -> {name, pressure(values)} end)}
    end)
  end

  defp pressure(%{total: total, available: available}) do
    used = max(total - available, 0)
    known = total > 0
    basis_points = if known, do: div(min(used, total) * 10_000, total), else: 0

    %{
      total: total,
      available: available,
      used: used,
      pressure_basis_points: basis_points,
      known: known
    }
  end
end
```

Implement `measurements/1` as a fixed flat map with `cas_bytes_*`, `cas_inodes_*`, `staging_bytes_*`, `staging_inodes_*`, `upload_nonterminal`, `delete_nonterminal`, and `blob_<state>` integer keys. Convert each boolean `known` field to a corresponding integer `*_known` measurement (`1` or `0`). Do not flatten dynamically or include arbitrary adapter/database values. Plan 3 must assert the complete `snapshot/0` field shape shown above, including the unknown-inode case.

- [ ] Emit one aggregate GC event and one aggregate integrity event with counts only:

```elixir
:telemetry.execute(
  [:fornacast, :release_assets, :gc, :stop],
  %{examined: examined, candidates: candidates, deleted: deleted, retries: retries, failures: failures},
  %{result: if(failures == 0, do: :ok, else: :partial)}
)

:telemetry.execute(
  [:fornacast, :release_assets, :integrity_audit, :stop],
  %{checked: checked, corrupt: corrupt, absent_reappeared: reappeared, failures: failures},
  %{mode: mode}
)
```

Never attach a digest, storage/staging path, ESS struct, raw exception, actor, repository authorization, credential, or failure text to telemetry.

- [ ] Add independent `BlobGCScheduler` and `StorageTelemetryScheduler` children after `RecoveryScheduler` in the `:one_for_all` subtree. Both start immediately, use the shared dispatch task supervisor, run only one task at a time, and correlate the exact reply/`:DOWN`/timeout refs:

```elixir
children = [
  Supervisor.child_spec(
    {Task.Supervisor, name: ForgeReleases.WorkTaskSupervisor},
    id: ForgeReleases.WorkTaskSupervisor
  ),
  ForgeReleases.TaskFence,
  Supervisor.child_spec(
    {Task.Supervisor, name: ForgeReleases.RecoveryDispatchSupervisor},
    id: ForgeReleases.RecoveryDispatchSupervisor
  ),
  ForgeReleases.RecoveryScheduler,
  ForgeReleases.BlobGCScheduler,
  ForgeReleases.StorageTelemetryScheduler
]
```

The GC scheduler retains and threads the due-row cursor. Its 25-second worker deadline is strictly below its 30-second outer timeout, and every inner delete is capped at five seconds and the remaining worker budget:

```elixir
defmodule ForgeReleases.BlobGCScheduler do
  use GenServer

  @interval_ms 30_000
  @work_budget_ms 25_000
  @runtime_ms 30_000

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    {:ok,
     %{
       task: nil,
       runtime_timer: nil,
       due_cursor: nil,
       monotonic_ms: Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
       task_supervisor:
         Keyword.get(options, :task_supervisor, ForgeReleases.RecoveryDispatchSupervisor),
       task_fun: Keyword.get(options, :task, &ForgeReleases.BlobGC.run_once/1)
     }, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state), do: {:noreply, state |> schedule() |> start_if_idle()}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> schedule() |> start_if_idle()}

  def handle_info(
        {ref, {:ok, %{next_due_cursor: cursor}}},
        %{task: %Task{ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil, due_cursor: cursor}}
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info({:runtime_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_if_idle(%{task: nil} = state) do
    deadline = state.monotonic_ms.() + @work_budget_ms
    task_fun = state.task_fun
    due_cursor = state.due_cursor

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        task_fun.(limit: 50, due_after_id: due_cursor, deadline_ms: deadline)
      end)

    timer = Process.send_after(self(), {:runtime_timeout, task.ref}, @runtime_ms)
    %{state | task: task, runtime_timer: timer}
  end

  defp start_if_idle(state), do: state

  defp schedule(state) do
    Process.send_after(self(), :tick, @interval_ms)
    state
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer, async: false, info: false)
end
```

Implement storage telemetry as its own cadence so a busy/erroring GC cannot suppress pressure reporting. A snapshot has a ten-second task timeout; failures are already normalized/emitted by `StorageTelemetry.emit/0`, do not crash the scheduler, and retry only on the next 60-second tick:

```elixir
defmodule ForgeReleases.StorageTelemetryScheduler do
  use GenServer

  @interval_ms 60_000
  @runtime_ms 10_000

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    {:ok,
     %{
       task: nil,
       runtime_timer: nil,
       task_supervisor:
         Keyword.get(options, :task_supervisor, ForgeReleases.RecoveryDispatchSupervisor),
       task_fun: Keyword.get(options, :task, &ForgeReleases.StorageTelemetry.emit/0)
     }, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state), do: {:noreply, state |> schedule() |> start_if_idle()}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> schedule() |> start_if_idle()}

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    cancel(state.runtime_timer)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info({:runtime_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    {:noreply, %{state | task: nil, runtime_timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_if_idle(%{task: nil} = state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, state.task_fun)
    timer = Process.send_after(self(), {:runtime_timeout, task.ref}, @runtime_ms)
    %{state | task: task, runtime_timer: timer}
  end

  defp start_if_idle(state), do: state

  defp schedule(state) do
    Process.send_after(self(), :tick, @interval_ms)
    state
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer, async: false, info: false)
end
```

In `storage_telemetry_test.exs`, inject a task that reports its calls and blocks. Assert immediate startup, no overlap on a tick while active, exact reply/`:DOWN` correlation, timeout termination, an error result leaving the scheduler alive, and the next cadence dispatching again. In `blob_gc_test.exs`, assert the scheduler threads `next_due_cursor`, preserves it across an error/timeout, and gives the worker five seconds of outer cleanup margin.

- [ ] Run GC/audit races repeatedly and commit:

```bash
mix format apps/forge_releases/lib/forge_releases/{blob_gc,blob_gc_scheduler,blob_inventory,integrity_audit,recovery_supervisor,release_asset_blob,storage_telemetry,storage_telemetry_scheduler}.ex \
  apps/forge_releases/test/{asset_download_test,blob_gc_test,blob_inventory_test,integrity_audit_test,storage_telemetry_test}.exs
for seed in 0 1 2; do
  mix test apps/forge_releases/test/asset_download_test.exs \
    apps/forge_releases/test/blob_gc_test.exs \
    apps/forge_releases/test/blob_inventory_test.exs \
    apps/forge_releases/test/integrity_audit_test.exs \
    apps/forge_releases/test/storage_telemetry_test.exs \
    --max-cases 1 --seed "$seed" || exit 1
done
```

Expected: all runs report `0 failures`; a local active delete fences reclaim after lease expiry, candidate attachment/deletion has one winner, physically present absent bytes are fenced and reported as corruption without automatic deletion, and telemetry contains aggregate safe values only.

```bash
git add apps/forge_releases/lib/forge_releases/{blob_gc,blob_gc_scheduler,blob_inventory,integrity_audit,recovery_supervisor,release_asset_blob,storage_telemetry,storage_telemetry_scheduler}.ex \
  apps/forge_releases/test/{asset_download_test,blob_gc_test,blob_inventory_test,integrity_audit_test,storage_telemetry_test}.exs
git commit -m "feat(releases): reclaim and audit LocalCAS blobs"
```

### Task 9: Prove the complete release domain on Turso and PostgreSQL

**Files:**

- Verify: `apps/forge_releases/lib/**/*.ex`
- Verify: `apps/forge_releases/test/**/*.exs`
- Verify: `apps/fornacast/priv/repo/migrations/20260812000100_create_release_domain.exs`
- Verify: `config/config.exs`

- [ ] Run a specification-coverage review before the test matrix. Every row must point to at least one named test, and no behavior may be deferred to Plan 3:

| Required domain proof | Named test file |
|---|---|
| retained existing/missing tag lifecycle and every publication observation | `forge_releases_test.exs`, `recovery_test.exs` |
| upload reader arity, latest state, exact-cap probe, overflow, zero-progress rejection, timeouts, lower cap, attach retry | `asset_upload_test.exs` |
| blob version touch, candidate reactivation, attachment-versus-GC winner | `blob_inventory_test.exs`, `blob_gc_test.exs` |
| linked task fence, renewal, lost owner, timeout, `:DOWN`, trap-exit restoration | `task_fence_test.exs` |
| ready-ledger-gated fd open, crash/fresh-BEAM expired-lease reclaim, stale slow-open close, malformed-result close, deadlines, audit/open race, count-after-EOF | `asset_download_test.exs`, `blob_inventory_test.exs`, `integrity_audit_test.exs` |
| immediate logical deletion, duplicate/shared digest, tag retention | `deletion_test.exs`, `recovery_test.exs` |
| total upload survivor matrix, monitored stat/verify, conditional corruption race, and two-pass idempotence | `recovery_test.exs` |
| fair tag/file/terminal cursors, terminal cleanup retry, and inner/outer deadline margin | `recovery_test.exs` |
| GC grace, stale selection, due cursor/wrap fairness, retry time, deadline margin, before/after unlink crash | `blob_gc_test.exs` |
| absent claim race, cursor-paged dry run, maintenance corruption transition without byte deletion, safe telemetry | `integrity_audit_test.exs` |
| CAS/staging byte and inode capacity/pressure, unknown inode support, operation/blob aggregates, scheduler cadence/redaction | `storage_telemetry_test.exs` |
| fresh Turso schema plus PostgreSQL checks/races | `release_domain_migration_test.exs`, all race files |

Expected: every row has an implemented assertion, not only a test name or commented example.

- [ ] Scan implementation files for placeholders, accidental boundary breaches, and the required dependency markers:

```bash
if rg -n 'TODO|TBD|placeholder|similar to' \
  apps/forge_releases/lib apps/forge_releases/test \
  apps/fornacast/priv/repo/migrations/20260812000100_create_release_domain.exs; then
  exit 1
fi

if rg -n 'WORKAROUND\(upstream\): gsmlg-opt/ex_storage_service#(13|14|15)' \
  apps/forge_releases/lib apps/forge_releases/test; then
  exit 1
fi

if rg -n 'ExStorageService|BlobStore\.LocalCAS|send_file|release_assets\.storage_path' \
  apps/forge_releases/lib \
  -g '!asset_storage.ex' -g '!asset_storage/**'; then
  exit 1
fi
```

Expected: all checks print nothing and exit `0`; no closed-upstream workaround marker remains. Confirm no per-object path, fd, ESS struct, reader state, credential, digest, or raw storage error appears in logs, audit metadata, telemetry metadata, or public structs.

- [ ] Verify formatting only for files changed by the eight implementation commits:

```bash
git diff --name-only --diff-filter=ACM HEAD~8..HEAD \
  | rg '\.(ex|exs)$' \
  | xargs mix format --check-formatted
```

Expected: exit status `0` and no formatter output. If commit count differs because an implementation task was split, replace `HEAD~8` with the commit immediately before Task 1; do not format unrelated files.

- [ ] Rebuild for default Turso and run the entire scoped app suite serially:

```bash
FORNACAST_DATABASE_ADAPTER=turso MIX_ENV=test mix clean
FORNACAST_DATABASE_ADAPTER=turso MIX_ENV=test mix ecto.migrate
FORNACAST_DATABASE_ADAPTER=turso MIX_ENV=test mix compile --warnings-as-errors
FORNACAST_DATABASE_ADAPTER=turso mix test apps/forge_releases/test \
  --max-cases 1 --seed 0
```

Expected: migration reports already up or migrates `20260812000100`; compilation has no warnings; all `forge_releases` foundation and domain tests report `0 failures`. The fresh-Turso migration test independently creates all five tables.

- [ ] With a running PostgreSQL 17 test service, force a clean adapter recompile and run the same scoped suite. Do not reuse artifacts compiled for Turso:

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test mix clean
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test mix ecto.migrate
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test \
  mix compile --warnings-as-errors
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test \
  mix test apps/forge_releases/test --max-cases 1 --seed 0
```

Expected: the checked-in devenv PostgreSQL 17 service supplies its Unix-socket `PGHOST`/`PGPORT` and `fornacast_test` database; PostgreSQL check constraints migrate; compilation has no warnings; all focused tests report `0 failures`, including real concurrent attachment/GC and metadata update/delete races. Do not override it with localhost credentials or a TCP port.

- [ ] Restore the default adapter build and repeat the concurrency-sensitive files with non-default seeds:

```bash
FORNACAST_DATABASE_ADAPTER=turso MIX_ENV=test mix clean
FORNACAST_DATABASE_ADAPTER=turso MIX_ENV=test mix compile --warnings-as-errors
for seed in 1 2 3 4; do
  FORNACAST_DATABASE_ADAPTER=turso mix test \
    apps/forge_releases/test/task_fence_test.exs \
    apps/forge_releases/test/blob_inventory_test.exs \
    apps/forge_releases/test/asset_upload_test.exs \
    apps/forge_releases/test/recovery_test.exs \
    apps/forge_releases/test/blob_gc_test.exs \
    apps/forge_releases/test/integrity_audit_test.exs \
    apps/forge_releases/test/storage_telemetry_test.exs \
    --max-cases 1 --seed "$seed" || exit 1
done
```

Expected: all four runs report `0 failures`; there are no mailbox leaks, stale task transitions, double quota adjustments, tag changes, or digest deletion races.

- [ ] Review the final eight-commit file set and stop at the Plan 2 boundary:

```bash
git diff --stat HEAD~8..HEAD
git diff --name-only HEAD~8..HEAD
git status --short
```

Expected: implementation changes are confined to `apps/forge_releases/**`, the one release-domain migration, and `config/config.exs`; status is clean. There are no `fornacast_api`, OpenAPI, client-script, Docker, Compose, deployment-workflow, S3, or LFS changes. Do not run production release/Docker acceptance here; proceed to `docs/superpowers/plans/2026-08-12-release-api-and-acceptance.md` only after this scoped evidence is green.

## Completion criteria

Plan 2 is complete only when all ten tasks (`Task 0` through `Task 9`) are checked, each of the eight implementation commits (`Task 1` through `Task 8`) exists, both database suites are green from clean adapter builds, every nonterminal and terminal-cleanup recovery branch passes twice, and the final scope scan is clean. `Task 0` is a prerequisite gate and `Task 9` is verification, so neither creates a commit. A successful upload alone, a passing LocalCAS adapter suite, or a terminal SQL delete with pending cleanup is not completion.
