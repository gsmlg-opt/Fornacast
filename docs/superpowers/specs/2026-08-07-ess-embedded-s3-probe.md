# ExStorageService Embedded LocalCAS and S3 Probe

**Original probe date:** 2026-08-07
**Revalidated:** 2026-08-11 against `ex_storage_service` v0.6.2
**Status:** Probe complete; technical embedding gates pass; no Fornacast product integration

## Decision

Fornacast can embed the Hex-published ExStorageService core and supervise a
LocalCAS instance in its BEAM. Fornacast's existing Concord Turso-backed
`ConfigStore` can run beside the singleton Concord/VSR engine used by ESS, and
both metadata stores plus LocalCAS survive a fresh BEAM restart.

The in-process S3 application also works at v0.6.2, but it is still not
published to Hex. Its supported embedding recipe uses same-tag sibling path
dependencies from an ESS source checkout. That packaging constraint remains a
product and release-build decision; it is not a runtime blocker for the probe.

Do not treat this result as approval to implement release assets, Git LFS, a
public S3 listener, or Compose changes. Those remain separate product work.

## Upstream issue status

All issues raised by the original v0.6.1 probe were fixed in
[v0.6.2](https://github.com/gsmlg-opt/ex_storage_service/releases/tag/v0.6.2),
tag commit `fb8b21948facbb24cd42260ec0ba57c18960efe2`:

| Issue | v0.6.2 result |
| --- | --- |
| [#7](https://github.com/gsmlg-opt/ex_storage_service/issues/7) | Embedding docs now include the required Concord 3 singleton VSR `members`. |
| [#8](https://github.com/gsmlg-opt/ex_storage_service/issues/8) | S3 standalone/path consumption is documented and its Mix paths are conditional. The S3 app was **not** published to Hex. |
| [#9](https://github.com/gsmlg-opt/ex_storage_service/issues/9) | Dead two-tuple reader error matches were removed from the S3 handlers. |

## Fresh probe evidence

### A. Hex core and LocalCAS

Probe host: `/tmp/ess_hex_embed_probe_v062`

Dependency:

```elixir
{:ex_storage_service, "0.6.2"}
```

The host disabled the ESS default instance, configured an explicit Concord 3
singleton VSR membership, and supervised `{ExStorageService, instance_options}`
itself. The focused test covered:

- application and host supervisor startup;
- `LocalCAS.stage/2` with expected SHA-256 and size;
- `LocalCAS.commit/2`;
- `LocalCAS.stat/2`;
- ranged `LocalCAS.open/3` and reading the returned file source;
- `LocalCAS.verify/2`.

Fresh result on 2026-08-11:

```text
mix test
1 test, 0 failures
```

The lock resolved ESS `0.6.2`, Concord `3.0.2`, and
`viewstamped_replication` `3.0.2`.

### B. Same-tag core and in-process S3

Probe host: `/tmp/ess_embed_probe_v062`

The source tree came from the verified v0.6.2 tag. Both applications were
loaded from that same tree. The preserved tag tarball SHA-256 is
`881b74533b0e2807994db1a6c450c77bbd21ff70b295f6cb5fc0a2d8c6fac9bf`:

```elixir
{:ex_storage_service,
 path: "vendor/ex_storage_service-0.6.2/apps/ex_storage_service"},
{:ex_storage_service_s3,
 path: "vendor/ex_storage_service-0.6.2/apps/ex_storage_service_s3"}
```

Runtime assertions checked that both application versions were `0.6.2`. The
host supervised the ESS instance, while the S3 application started its own
Bandit listener on an ephemeral loopback port with authentication disabled.
The tests covered:

- the same LocalCAS lifecycle and ranged file read as the Hex probe;
- S3 `CreateBucket` returning `201`;
- S3 `PutObject` returning `200` with an ETag;
- S3 `GetObject` returning `200` with the original body.

Fresh result on 2026-08-11:

```text
mix test --trace
2 tests, 0 failures
```

The unauthenticated listener was loopback-only and existed only for this
ephemeral probe. No probe credentials were created or persisted.

### C. Fornacast Concord coexistence and restart

Spike worktree:

```text
.trees/ess-concord-coexistence-spike
branch: codex/ess-concord-coexistence-spike
```

The spike is test-only and uncommitted. It adds exact ESS core `0.6.2` as a
test dependency, disables ESS auto-start in test config, and attaches the ESS
instance dynamically beneath `Fornacast.Supervisor`. It does not add product
storage APIs, S3, release wiring, LFS, runtime configuration, or deployment
changes.

The important Concord configuration shape is:

```elixir
config :concord,
  cluster_enabled: true,
  data_dir: ess_metadata_root,
  vsr: [
    group_id: :ex_storage_service_metadata,
    replica_id: node(),
    members: [%{id: node(), endpoint: node()}],
    storage: :file,
    bootstrap: false
  ],
  turso: [
    enabled: true,
    database: fornacast_config_database,
    pool_size: 1
  ]
```

This is not two Concord applications. One Concord supervision tree starts both
engines:

- `Fornacast.ConfigStore` explicitly calls `Concord.Turso.*`;
- ESS metadata calls the default `Concord.*` API, which selects VSR.

Two separate `MIX_ENV=test mix run --no-start` BEAM invocations used identical
roots, VSR group membership, and node identity:

1. The first boot started Fornacast and ESS, wrote a ConfigStore value through
   Turso, created an ESS bucket through VSR, and committed a 52-byte LocalCAS
   blob with SHA-256
   `61b3c729d5b888a2dafb44cb3416a1a248bbb114fcb4f3cad4334f9e99ee2519`.
2. The second boot recovered the ConfigStore value, bucket metadata, blob size,
   integrity result, and the expected ranged bytes from the same LocalCAS file.

Both invocations exited `0`. The pre-ESS focused baseline and the focused test
after adding the test dependency both reported:

```text
mix test apps/fornacast/test/fornacast_config_store_test.exs
1 test, 0 failures
```

## Operational constraints discovered

- Fornacast already resolves Concord `3.0.2`; no Concord major-version upgrade
  is required before an ESS spike.
- `cluster_enabled: true` is required to start Concord's VSR supervisor.
  Supplying `vsr:` while leaving the flag false is insufficient.
- Turso and VSR must use separate durable paths. ESS instance roots must match
  the application and Concord metadata roots.
- Concord/VSR remains singleton shared infrastructure in a BEAM. This probe
  assigns that one VSR group to ESS; `ConfigStore` remains on Turso.
- A restart test must use a fresh BEAM. Stopping only the Fornacast application
  leaves dependency applications running and does not prove recovery.
- Hex registry access was intermittently unavailable. Offline resolution from
  the verified cache succeeded without changing versions.
- `ex_storage_service_s3` remains source/path-only. A self-contained Fornacast
  release must either gain a published aligned package or adopt an explicit,
  reproducible source dependency policy.

## Recommendation

The embed feasibility question is green for ESS v0.6.2. The subsequent design,
`docs/superpowers/specs/2026-08-12-release-assets-localcas-design.md`, puts
LocalCAS behind the releases plan's opaque `AssetStorage` boundary and
deliberately excludes the S3 application from the first product slice. S3
packaging is therefore deferred to a separate approved design rather than
acting as a release-asset implementation gate.

The existing releases plan remains authoritative:
`docs/superpowers/plans/2026-07-21-github-api-releases.md`. Git LFS remains out
of v0.1 scope unless separately approved.
