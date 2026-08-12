# ExStorageService Embedded LocalCAS and S3 Probe

**Original probe date:** 2026-08-07
**Revalidated:** 2026-08-12 against Hex `ex_storage_service` v0.6.4
**Status:** Probe complete; technical embedding gates pass; no Fornacast product integration

## Decision

Fornacast can embed the Hex-published ExStorageService v0.6.4 core and supervise
a LocalCAS instance with a host-owned Concord 3 singleton VSR in the same BEAM.

The historical v0.6.2 Fornacast spike established that its Turso-backed
`ConfigStore` can coexist with ESS's VSR metadata and LocalCAS. The current
v0.6.4 probe reconfirmed VSR metadata and LocalCAS persistence across BEAMs.

The historical v0.6.2 probe also showed that the in-process S3 application
worked through same-tag sibling path dependencies from an ESS source checkout.
S3 was not revalidated against v0.6.4, so this document makes no v0.6.4 S3
claim.

Do not treat this result as approval to implement release assets, Git LFS, a
public S3 listener, or Compose changes. Those remain separate product work.

## Upstream issue status

Issues #13, #14, and #15 were closed through
[#16](https://github.com/gsmlg-opt/ex_storage_service/pull/16).

The fixes were released in
[v0.6.4](https://github.com/gsmlg-opt/ex_storage_service/releases/tag/v0.6.4),
tag commit `0019f60a22248f865cf24268b6eb11905af24943`:

| Issue | v0.6.4 result |
| --- | --- |
| [#13](https://github.com/gsmlg-opt/ex_storage_service/issues/13) | Added public `LocalCAS.recover_stage/4` for verified, zero-copy recovery of caller-owned completed stages. |
| [#14](https://github.com/gsmlg-opt/ex_storage_service/issues/14) | Added documented `Context.direct_blob_store_options/1` for loose-only LocalCAS access without pack or legacy metadata lookup. |
| [#15](https://github.com/gsmlg-opt/ex_storage_service/issues/15) | Made `LocalCAS.delete/2` sync the containing directory and documented safe retry after an ambiguous post-unlink sync failure. |

### Historical v0.6.2 issues

All issues raised by the original v0.6.1 probe were fixed in
[v0.6.2](https://github.com/gsmlg-opt/ex_storage_service/releases/tag/v0.6.2),
tag commit `fb8b21948facbb24cd42260ec0ba57c18960efe2`:

| Issue | v0.6.2 result |
| --- | --- |
| [#7](https://github.com/gsmlg-opt/ex_storage_service/issues/7) | Embedding docs now include the required Concord 3 singleton VSR `members`. |
| [#8](https://github.com/gsmlg-opt/ex_storage_service/issues/8) | S3 standalone/path consumption is documented and its Mix paths are conditional. The S3 app was **not** published to Hex. |
| [#9](https://github.com/gsmlg-opt/ex_storage_service/issues/9) | Dead two-tuple reader error matches were removed from the S3 handlers. |

## Fresh probe evidence

### A. Current v0.6.4 Hex core and LocalCAS

Probe host: `/tmp/ess_hex_embed_probe_v064`

Dependency:

```elixir
{:ex_storage_service, "0.6.4"}
```

A fresh Hex resolution selected ESS `0.6.4`, Concord `3.0.3`,
`viewstamped_replication` `3.0.3`, and `ex_turso` `3.0.3`. Fornacast remains
locked to Concord `3.0.2`; that version still satisfies ESS's `~> 3.0`
constraint.

The host configured the Concord singleton VSR, disabled ESS auto-start and
optional filesystem workers, and supervised `{ExStorageService,
instance_options}` itself. The focused probe covered:

- `Context.direct_blob_store_options/1`, including `pack_module: nil` and no
  legacy bucket;
- `LocalCAS.stage_from_reader/3` with final reader state, expected lowercase
  SHA-256, size, and a bounded maximum;
- `LocalCAS.recover_stage/4` for the completed caller-owned stage;
- `commit/2`, `stat/2`, ranged `open/3`, `:file.pread/3`, `:file.close/1`, and
  `verify/2`;
- `delete/2` for an already missing digest;
- an ambiguous simulated directory-sync failure after unlink, followed by
  successful absence verification and repeated successful deletion retries;
  and
- supervised ESS child termination and restart while the host-owned Concord
  VSR supervisor retained the same PID.

Fresh result on 2026-08-12:

```text
ESS_PROBE_ROOT=<fresh-root> mix test --trace
2 tests, 0 failures
```

Two separate BEAM invocations against
`/tmp/ess-v064-fresh-clean-RD35Ek` then proved VSR metadata and LocalCAS bytes
persisted together:

```text
ESS_PROBE_ROOT=/tmp/ess-v064-fresh-clean-RD35Ek mix run scripts/fresh_beam_probe.exs write
WRITE_OK hash=ef5d6cd15c2ca08ea43fb7e6048a2db892b179a4b472aa15d2ffa84d2e3b9fe2 size=47 reads=5 vsr=alive ess_child=alive
ESS_PROBE_ROOT=/tmp/ess-v064-fresh-clean-RD35Ek mix run scripts/fresh_beam_probe.exs read
READ_OK hash=ef5d6cd15c2ca08ea43fb7e6048a2db892b179a4b472aa15d2ffa84d2e3b9fe2 size=47 concord=persisted local_cas=persisted vsr=alive ess_child=alive
```

`LocalCAS.open/3` returns a bounded file source rather than a LocalCAS-owned
handle. Reading and closing therefore use `:file`, as exercised above.

### B. Historical v0.6.2 Hex core and LocalCAS

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

### C. Historical v0.6.2 same-tag core and in-process S3

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

This S3/path-dependency result was not rerun against v0.6.4.

### D. Historical v0.6.2 Fornacast Concord coexistence and restart

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

- Fornacast remains locked to Concord `3.0.2`, which satisfies ESS v0.6.4's
  `~> 3.0` constraint. The isolated v0.6.4 probe's fresh resolver selected
  Concord `3.0.3`; no Concord major-version upgrade is required.
- `cluster_enabled: true` is required to start Concord's VSR supervisor.
  Supplying `vsr:` while leaving the flag false is insufficient.
- Turso and VSR must use separate durable paths. ESS instance roots must match
  the application and Concord metadata roots.
- Concord/VSR remains singleton shared infrastructure in a BEAM. This probe
  assigns that one VSR group to ESS; `ConfigStore` remains on Turso.
- A restart test must use a fresh BEAM. Stopping only the Fornacast application
  leaves dependency applications running and does not prove recovery.
- During the historical v0.6.2 probe, intermittent Hex access required cached
  resolution. The v0.6.4 probe resolved its published dependencies online.
- The only S3 packaging evidence in this document is the historical v0.6.2
  source/path probe. S3 remains outside the LocalCAS release-asset slice and
  was not retested at v0.6.4.

## Recommendation

The embed feasibility question is green for Hex ESS core v0.6.4. The subsequent
design, `docs/superpowers/specs/2026-08-12-release-assets-localcas-design.md`,
puts LocalCAS behind the releases plan's opaque `AssetStorage` boundary.

The first product slice deliberately excludes S3. Its packaging and any v0.6.4
validation remain deferred to a separate approved design rather than acting as
a release-asset implementation gate.

The old `docs/superpowers/plans/2026-07-21-github-api-releases.md` plan is now
explicitly superseded. Execute the approved LocalCAS foundation, release-domain,
and API/acceptance plans dated 2026-08-12 in order. Git LFS remains out of v0.1
scope unless separately approved.
