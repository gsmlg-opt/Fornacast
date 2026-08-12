# Release API and Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the completed LocalCAS-backed release domain through the pinned GitHub-compatible REST surface and prove the complete client, supervision, garbage-collection, backup, release, and Docker workflows.

**Architecture:** Keep the HTTP layer thin: versioned validators and serializers translate the public contract, while `ReleaseController` and `ReleaseAssetController` authorize an already-resolved repository and call `ForgeReleases`. Raw uploads use a credential-free opaque `UploadReader` state passed once to `ForgeReleases.stream_asset_upload/3`; downloads retain the opaque bounded reader from Plan 2. Acceptance runs through the public nginx origin and separately inspects the released OTP system to prove LocalCAS readiness, disabled ESS workers, S3 absence, delayed GC, and cold recovery-set restore.

**Tech Stack:** Elixir 1.20, OTP 29, Phoenix 1.8, Plug/Bandit, Ecto 3.14 with Turso and PostgreSQL, ExStorageService 0.6.2 core, Concord 3, OpenAPI 3.0, Node/npm with Octokit, GitHub CLI, Docker Compose, nginx, and ExUnit.

---

**Approved specifications:**

- `docs/superpowers/specs/2026-07-21-github-compatible-api-design.md`
- `docs/superpowers/specs/2026-08-12-release-assets-localcas-design.md`

**Required predecessors:**

1. Plan 1: `docs/superpowers/plans/2026-08-12-release-assets-localcas-foundation.md`
2. Plan 2: `docs/superpowers/plans/2026-08-12-release-domain-on-localcas.md`
3. The API foundation, Git-data, issue, and pull-request delivery slices through marker `4`.

Do not start this plan until the two predecessor plans are committed and their focused suites pass. This plan replaces Tasks 6 and 7 of `docs/superpowers/plans/2026-07-21-github-api-releases.md`; do not execute those older tasks as a second implementation.

The predecessor plans must expose these exact contracts before this plan starts:

```elixir
@spec begin_asset_upload(repository(), release(), map(), actor(), request_metadata()) ::
        {:ok, upload()} | {:error, error_reason()}

@type repository :: ForgeRepos.Repository.t()
@type release :: ForgeReleases.Release.t()
@type asset :: ForgeReleases.Asset.t()
@type actor :: ForgeAccounts.User.t()
@type request_metadata :: %{
        required(:request_id) => String.t(),
        required(:ip_address) => :inet.ip_address(),
        required(:user_agent) => String.t()
      }
@type upload :: ForgeReleases.Upload.t()
@type asset_download :: ForgeReleases.AssetDownload.t()
@type error_reason :: ForgeReleases.error_reason()

@type reader_state :: term()
@type reader_result(state) ::
        {:more, binary(), state}
        | {:ok, binary(), state}
        | {:done, state}
        | {:error, term(), state}
@type reader(state) :: (state, keyword() -> reader_result(state))

@spec stream_asset_upload(upload(), reader(state), state) ::
        {:ok, asset(), state} | {:error, error_reason(), state}
        when state: term()

@spec abort_asset_upload(upload(), error_reason()) ::
        :ok | {:error, error_reason()}

@spec open_asset(repository(), asset(), actor() | nil) ::
        {:ok, asset_download()} | {:error, error_reason()}
@spec asset_download_metadata(asset_download()) ::
        %{size: non_neg_integer(), content_type: String.t(), disposition: String.t()}
@spec read_asset_chunk(asset_download(), pos_integer()) ::
        {:ok, binary(), asset_download()} | :eof | {:error, error_reason()}
@spec close_asset_download(asset_download()) :: :ok
@spec record_download(repository(), asset()) :: :ok | {:error, error_reason()}

@spec ForgeReleases.AssetStorage.ready?() :: boolean()
@spec ForgeReleases.BlobGC.run_once(keyword()) ::
        {:ok, %{
          examined: non_neg_integer(),
          candidates: non_neg_integer(),
          deleted: non_neg_integer(),
          retries: non_neg_integer(),
          failures: non_neg_integer(),
          next_due_cursor: non_neg_integer() | nil
        }}
        | {:error, {:unavailable, atom()}}
@spec ForgeReleases.IntegrityAudit.run(keyword()) ::
        {:ok, %{
          checked: non_neg_integer(),
          corrupt: non_neg_integer(),
          absent_reappeared: non_neg_integer(),
          absent_redeleted: non_neg_integer(),
          failures: non_neg_integer(),
          next_cursor: non_neg_integer() | nil,
          blob_states: map(),
          blobs: [%{digest: String.t(), size: non_neg_integer(), state: atom()}],
          integrity_failures: [%{digest: String.t(), failure: atom()}]
        }}
        | {:error, {:unavailable, atom()}}
@spec ForgeReleases.StorageTelemetry.snapshot() ::
        {:ok, %{
          capacity: %{
            cas: %{
              bytes: %{
                total: non_neg_integer(),
                available: non_neg_integer(),
                used: non_neg_integer(),
                pressure_basis_points: 0..10_000,
                known: boolean()
              },
              inodes: %{
                total: non_neg_integer(),
                available: non_neg_integer(),
                used: non_neg_integer(),
                pressure_basis_points: 0..10_000,
                known: boolean()
              }
            },
            staging: %{
              bytes: %{
                total: non_neg_integer(),
                available: non_neg_integer(),
                used: non_neg_integer(),
                pressure_basis_points: 0..10_000,
                known: boolean()
              },
              inodes: %{
                total: non_neg_integer(),
                available: non_neg_integer(),
                used: non_neg_integer(),
                pressure_basis_points: 0..10_000,
                known: boolean()
              }
            }
          },
          operations: %{
            upload_nonterminal: non_neg_integer(),
            delete_nonterminal: non_neg_integer()
          },
          blob_states: %{
            absent: non_neg_integer(),
            pending: non_neg_integer(),
            ready: non_neg_integer(),
            candidate: non_neg_integer(),
            deleting: non_neg_integer(),
            corrupt: non_neg_integer()
          }
        }}
        | {:error, {:unavailable, :asset_storage | :release_persistence}}
```

`BlobGC.run_once/1` accepts `now: DateTime.t()` for deterministic acceptance.
`IntegrityAudit.run/1` accepts `mode: :dry_run, limit: 50, after_id: nil` and
returns a `next_cursor` that callers thread until `nil`. Dry run must not change
bytes, blob state, integrity metadata, or user-visible SQL; it may acquire and
release a short coordination lease, incrementing only the retained blob row's
fencing version so verification cannot race deletion. If Plan 2 names either
operational function differently, reconcile both plans before implementation;
do not add an API-layer alias.

## Scope guardrails

- Implement only the release and release-asset operations already present in delivery slice `5` of the pinned OpenAPI documents.
- Keep source archives `tarball_url` and `zipball_url` as `null`; do not implement archive generation.
- Keep the `/api/uploads` prefix as a distinct public server path. nginx must forward it without prefix stripping or request buffering.
- Never put an Authorization header, PAT, API-key struct, storage path, ESS struct, or raw filesystem error in the reader state, logs, audit metadata, fixtures, or acceptance artifacts.
- A default asset `GET` returns JSON. Only `Accept: application/octet-stream` streams bytes.
- Do not call LocalCAS from controllers, serializers, scripts, or tests outside the Plan 1 adapter contract. Operational acceptance uses `ForgeReleases.BlobGC`, `ForgeReleases.IntegrityAudit`, and `ForgeReleases.StorageTelemetry`.
- Do not weaken the one-BEAM, one-exclusive-volume, stop-before-start deployment constraint.
- Keep all acceptance credentials in process memory or mode-0600 files under the isolated acceptance directory. Never print them.
- Format only touched files and run the scoped commands in each task. The full release gate belongs to Task 5.

## File map

### REST contract and adapters

- Modify `apps/fornacast_api/mix.exs` to depend on `forge_releases`.
- Modify `apps/fornacast_api/lib/fornacast_api/router.ex` for ordered metadata and upload routes.
- Modify `apps/fornacast_api/lib/fornacast_api/error.ex` for release-domain HTTP mappings.
- Modify `apps/fornacast_api/lib/fornacast_api/url.ex` for canonical release, asset, browser-download, and upload-template URLs.
- Modify `apps/fornacast_api/lib/fornacast_api/plugs/authentication.ex` to consume the Authorization header while retaining only safe response-scope data.
- Modify `apps/fornacast_api/lib/fornacast_api/plugs/request_context.ex` to expose safe release request metadata and preserve OAuth response headers after reader-state redaction.
- Modify `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex` for the one raw upload route and binary asset downloads.
- Modify `apps/fornacast_api/lib/fornacast_api/controllers/health_controller.ex` to report release-asset storage readiness without changing its status policy.
- Create `apps/fornacast_api/lib/fornacast_api/upload_reader.ex` as the only Plug-to-domain body reader.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/release_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/release_asset_controller.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex` and `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/release.ex` and `release_asset.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/release.ex` and `release_asset.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializer.ex` with shared release/asset field construction.
- Modify `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex` and `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/release.ex` and `release_asset.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/release.ex` and `release_asset.ex`.
- Modify the two pinned files under `apps/fornacast_api/priv/openapi/` and `fornacast-overlay.json` only through `scripts/prune_github_openapi.exs`.
- Modify `apps/fornacast_web/mix.exs` to depend explicitly on `forge_releases`.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/health_controller.ex` to report the same readiness check while preserving disabled-SSH semantics.

### API tests and fixtures

- Modify `apps/fornacast_api/test/authentication_test.exs` to prove credential consumption on every authentication outcome.
- Modify `apps/fornacast_api/test/support/conn_case.ex` so release tables are reset in dependency order.
- Modify `apps/fornacast_api/test/endpoint_test.exs` for ready/degraded health responses and live API/repository reads.
- Create `apps/fornacast_api/test/support/scripted_conn_adapter.ex` for deterministic body reads, timeouts, disconnects, and chunk responses.
- Create `apps/fornacast_api/test/release_controller_test.exs`.
- Create `apps/fornacast_api/test/release_asset_stream_test.exs`.
- Create `apps/fornacast_api/test/release_contract_test.exs`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/release.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/release-list.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset-list.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/release.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/release-list.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset-list.json`.
- Modify `apps/fornacast_web/test/fornacast_web_test.exs` for ready/degraded health responses and a live repository page.

### Client and production acceptance

- Create `apps/fornacast_api/test/github_workflow_acceptance_test.exs`.
- Create `scripts/github-api-acceptance/package.json`.
- Create `scripts/github-api-acceptance/provision.exs`.
- Create `scripts/github-api-acceptance/octokit-workflow.mjs`.
- Create `scripts/github-api-acceptance/gh-workflow.sh`.
- Create `scripts/github-api-acceptance/runtime-gate.exs`.
- Create `scripts/github-api-acceptance/docker-storage-gate.sh`.
- Create `scripts/github-api-acceptance/docker-backup-restore-gate.sh`.
- Modify root `package.json` and `package-lock.json` for the isolated acceptance workspace.
- Modify `.dockerignore` and `.gitignore` to exclude all `e2e-data` recovery and credential artifacts.
- Modify `.github/workflows/e2e.yml` for both-adapter contract tests and the public-origin Docker gate.
- Modify `README.md` with the cold backup/restore recovery set and exclusive-volume constraint.

### Task 1: Add the versioned release metadata contract

**Files:**

- Modify: `apps/fornacast_api/mix.exs`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/error.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/url.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/release_asset.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/release_asset.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializer.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/release_asset.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/release_asset.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/release_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/release_asset_controller.ex`
- Create: `apps/fornacast_api/test/release_controller_test.exs`
- Create: `apps/fornacast_api/test/release_contract_test.exs`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/release.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/release-list.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset-list.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/release.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/release-list.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset-list.json`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`
- Modify: `apps/fornacast_api/priv/openapi/fornacast-overlay.json`

- [ ] **Step 1: Write failing route, authorization, validation, and literal-contract tests**

In `release_controller_test.exs`, build a public and a private repository, a writer and reader, one draft and one published release, and assets through Plan 2 helpers. Cover every route and assert route ordering prevents `latest`, `tags/:tag`, and `assets/:asset_id` from being consumed by `:release_id`. Use this table as the exact response contract:

```elixir
@release_cases [
  {:index, :get, "/api/v3/repos/alice/demo/releases", 200},
  {:create, :post, "/api/v3/repos/alice/demo/releases", 201},
  {:latest, :get, "/api/v3/repos/alice/demo/releases/latest", 200},
  {:by_tag, :get, "/api/v3/repos/alice/demo/releases/tags/v1.0.0", 200},
  {:show, :get, "/api/v3/repos/alice/demo/releases/9001", 200},
  {:update, :patch, "/api/v3/repos/alice/demo/releases/9001", 200},
  {:assets, :get, "/api/v3/repos/alice/demo/releases/9001/assets", 200},
  {:asset, :get, "/api/v3/repos/alice/demo/releases/assets/9101", 200},
  {:asset_update, :patch, "/api/v3/repos/alice/demo/releases/assets/9101", 200},
  {:asset_delete, :delete, "/api/v3/repos/alice/demo/releases/assets/9101", 204},
  {:delete, :delete, "/api/v3/repos/alice/demo/releases/9001", 204}
]

test "release route ownership is exact", %{conn: conn} do
  Enum.each(@release_cases, fn {_name, method, path, expected_status} ->
    conn = request_as_writer(conn, method, path)
    assert conn.status == expected_status
  end)
end

test "private and draft releases are masked before body consumption", %{conn: conn} do
  conn =
    conn
    |> put_req_header("user-agent", "release-contract-test")
    |> put_req_header("content-type", "application/json")
    |> request(:patch, "/api/v3/repos/alice/private/releases/9001", ~s({"name":"hidden"}))

  assert conn.status == 404
  refute_received {:request_body_read, _bytes}
end
```

In `release_contract_test.exs`, use literal maps rather than calling the serializer under test to construct expectations. The fixed values are release ID `9001`, asset ID `9101`, user ID `41`, owner/repository `alice/demo`, base URL `https://forge.example.test`, and timestamp `2026-07-21T00:00:00Z`. The exact release and asset maps are:

```elixir
@author %{
  avatar_url: "https://forge.example.test/alice",
  events_url: "https://forge.example.test/api/v3/users/alice/events{/privacy}",
  followers_url: "https://forge.example.test/api/v3/users/alice/followers",
  following_url: "https://forge.example.test/api/v3/users/alice/following{/other_user}",
  gists_url: "https://forge.example.test/api/v3/users/alice/gists{/gist_id}",
  gravatar_id: nil,
  html_url: "https://forge.example.test/alice",
  id: 41,
  login: "alice",
  node_id: "VXNlcjo0MQ",
  organizations_url: "https://forge.example.test/api/v3/users/alice/orgs",
  received_events_url: "https://forge.example.test/api/v3/users/alice/received_events",
  repos_url: "https://forge.example.test/api/v3/users/alice/repos",
  site_admin: false,
  starred_url: "https://forge.example.test/api/v3/users/alice/starred{/owner}{/repo}",
  subscriptions_url: "https://forge.example.test/api/v3/users/alice/subscriptions",
  type: "User",
  url: "https://forge.example.test/api/v3/users/alice"
}

@asset %{
  browser_download_url: "https://forge.example.test/api/v3/repos/alice/demo/releases/assets/9101",
  content_type: "application/gzip",
  created_at: "2026-07-21T00:00:00Z",
  digest: "sha256:" <> String.duplicate("a", 64),
  download_count: 0,
  id: 9101,
  label: "Linux",
  name: "fornacast.tar.gz",
  node_id: "UmVsZWFzZUFzc2V0OjkxMDE",
  size: 12,
  state: "uploaded",
  updated_at: "2026-07-21T00:00:00Z",
  uploader: @author,
  url: "https://forge.example.test/api/v3/repos/alice/demo/releases/assets/9101"
}

@release %{
  assets: [@asset],
  assets_url: "https://forge.example.test/api/v3/repos/alice/demo/releases/9001/assets",
  author: @author,
  body: "First release",
  created_at: "2026-07-21T00:00:00Z",
  draft: false,
  html_url: "https://forge.example.test/api/v3/repos/alice/demo/releases/9001",
  id: 9001,
  name: "Version 1.0.0",
  node_id: "UmVsZWFzZTo5MDAx",
  prerelease: false,
  published_at: "2026-07-21T00:00:00Z",
  tag_name: "v1.0.0",
  target_commitish: "main",
  tarball_url: nil,
  upload_url:
    "https://forge.example.test/api/uploads/repos/alice/demo/releases/9001/assets{?name,label}",
  url: "https://forge.example.test/api/v3/repos/alice/demo/releases/9001",
  zipball_url: nil
}
```

Assert both selected versions render these literal maps, the eight checked-in fixture files decode to these maps or one-element lists, and every fixture validates against its selected pinned response schema. Assert list pagination links, writer-only drafts/mutations, public/private masking, accepted scopes, duplicate names/tags, unsupported fields, and all error statuses.

- [ ] **Step 2: Run the tests and verify the release HTTP layer is absent**

Run:

```bash
mix test apps/fornacast_api/test/release_controller_test.exs apps/fornacast_api/test/release_contract_test.exs --max-cases 1
```

Expected: FAIL because the release controllers, validators, serializers, routes, and fixture files do not exist; the catch-all returns `404` and the implemented-through marker remains `4`.

- [ ] **Step 3: Advance the generated OpenAPI marker to slice 5**

Use a fresh temporary directory and the already-pinned GitHub REST description commit:

```bash
OPENAPI_SOURCE_DIR="$(mktemp -d)"
git clone --filter=blob:none --no-checkout https://github.com/github/rest-api-description.git "$OPENAPI_SOURCE_DIR"
git -C "$OPENAPI_SOURCE_DIR" checkout 03ca9c1cac754ec9b8369dc75de8a8c753c6e087 -- \
  descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json \
  descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json
mix run scripts/prune_github_openapi.exs -- "$OPENAPI_SOURCE_DIR" apps/fornacast_api/priv/openapi 5
```

Expected: source commit/blob checks pass; the delivery manifest and `/api/uploads` server override remain unchanged; only generated slice-5 material and the implemented-through marker advance. Keep the generated files exact; do not hand-edit minified JSON.

- [ ] **Step 4: Add strict versioned validators and canonical URL/field builders**

Add `{:forge_releases, in_umbrella: true}` to `fornacast_api`. Implement each version-specific validator module with the same explicit first-release fields, while keeping separate modules so later version drift remains local:

```elixir
defmodule FornacastAPI.Validators.V2022_11_28.Release do
  @create %{
    "tag_name" => :string,
    "target_commitish" => :string,
    "name" => :nullable_string,
    "body" => :nullable_string,
    "draft" => :boolean,
    "prerelease" => :boolean
  }
  @update Map.take(@create, ["name", "body", "draft", "prerelease"])

  def validate(:create_release, body),
    do: validate_fields(body, "Release", @create, ["tag_name"])

  def validate(:update_release, body),
    do: validate_fields(body, "Release", @update, [])

  defp validate_fields(body, resource, fields, required) do
    predicates = Map.new(fields, fn {name, type} -> {name, predicate(type)} end)
    FornacastAPI.RequestValidator.validate_fields(body, resource, predicates, required)
  end

  defp predicate(:string), do: &is_binary/1
  defp predicate(:nullable_string), do: &(is_nil(&1) or is_binary(&1))
  defp predicate(:boolean), do: &is_boolean/1
end

defmodule FornacastAPI.Validators.V2022_11_28.ReleaseAsset do
  @fields %{"name" => :string, "label" => :nullable_string}

  def validate(:update_release_asset, body) do
    predicates = Map.new(@fields, fn
      {name, :string} -> {name, &is_binary/1}
      {name, :nullable_string} -> {name, &(is_nil(&1) or is_binary(&1))}
    end)

    FornacastAPI.RequestValidator.validate_fields(
      body,
      "ReleaseAsset",
      predicates,
      []
    )
  end
end
```

Create equivalent `V2026_03_10` modules with the same explicit maps; do not delegate one API version to the other. Wire the facade modules by exact operation name.

Extend `FornacastAPI.URL` with these helpers:

```elixir
def release(owner, repo, id),
  do: repository(owner, repo) <> "/releases/#{positive_id(id)}"

def releases(owner, repo), do: repository(owner, repo) <> "/releases"
def release_assets(owner, repo, id), do: release(owner, repo, id) <> "/assets"

def release_asset(owner, repo, asset_id),
  do: repository(owner, repo) <> "/releases/assets/#{positive_id(asset_id)}"

def release_upload_template(owner, repo, release_id) do
  upload(
    "/repos/#{segment(owner)}/#{segment(repo)}/releases/#{positive_id(release_id)}/assets"
  ) <> "{?name,label}"
end

defp positive_id(id) when is_integer(id) and id > 0, do: Integer.to_string(id)
defp positive_id(id), do: raise(ArgumentError, "expected a positive integer ID, got: #{inspect(id)}")
```

Add shared `Serializer.Fields.release/2` and `release_asset/2` builders that take Plan 2's hydrated release/asset structs, never query a context, and emit every field shown in the literal maps. Each version module takes an explicit key list:

```elixir
@release_keys ~w(
  assets assets_url author body created_at draft html_url id name node_id prerelease
  published_at tag_name target_commitish tarball_url upload_url url zipball_url
)a

@asset_keys ~w(
  browser_download_url content_type created_at digest download_count id label name node_id
  size state updated_at uploader url
)a

def render(:release, value, opts),
  do: value |> Fields.release(opts) |> Map.take(@release_keys)

def render(:release_asset, value, opts),
  do: value |> Fields.release_asset(opts) |> Map.take(@asset_keys)
```

`digest` is rendered as `"sha256:" <> asset.sha256_digest`; storage keys and ESS data are never rendered. `html_url` deliberately equals the public API release URL until a web release page is designed.

- [ ] **Step 5: Add ordered routes and thin metadata controllers**

Add the routes in this exact order before the existing catch-all:

```elixir
get "/repos/:owner/:repo/releases/latest", ReleaseController, :latest
get "/repos/:owner/:repo/releases/tags/:tag", ReleaseController, :by_tag
get "/repos/:owner/:repo/releases/assets/:asset_id", ReleaseAssetController, :show
patch "/repos/:owner/:repo/releases/assets/:asset_id", ReleaseAssetController, :update
delete "/repos/:owner/:repo/releases/assets/:asset_id", ReleaseAssetController, :delete
get "/repos/:owner/:repo/releases/:release_id/assets", ReleaseAssetController, :index
get "/repos/:owner/:repo/releases", ReleaseController, :index
post "/repos/:owner/:repo/releases", ReleaseController, :create
get "/repos/:owner/:repo/releases/:release_id", ReleaseController, :show
patch "/repos/:owner/:repo/releases/:release_id", ReleaseController, :update
delete "/repos/:owner/:repo/releases/:release_id", ReleaseController, :delete
```

Use the established authorization order in every action: obtain the optional or required actor, resolve the repository through `ForgeRepos.fetch_authorized_repository/4`, authorize its visibility and mutation scope, then read/validate JSON if the action has a body. The action-to-domain mapping is exact:

```elixir
@actions %{
  index: {ForgeReleases, :list_releases, 3, 200},
  latest: {ForgeReleases, :latest_release, 2, 200},
  by_tag: {ForgeReleases, :get_release_by_tag, 3, 200},
  show: {ForgeReleases, :get_release, 3, 200},
  create: {ForgeReleases, :create_release, 4, 201},
  update: {ForgeReleases, :update_release, 5, 200},
  delete: {ForgeReleases, :delete_release, 4, 204}
}
```

For create/update, call `RequestBody.read_json(conn, :ordinary, [])` only after repository visibility, writer permission, and `ForgeAccounts.APIScope.authorize/3` succeed. Pass only `RequestContext.safe_metadata(conn)` to the domain. For asset index/show/update/delete, call the matching Plan 2 context function; controllers never query Ecto or storage.

Extend `Error.from_domain/2` with these explicit clauses before the fallback:

```elixir
def from_domain({:payload_too_large, :asset}, url),
  do: new(413, "Payload Too Large", url)

def from_domain({:request_timeout, :asset}, url),
  do: new(408, "Request Timeout", url)

def from_domain(:already_exists, url),
  do: new(422, "Validation Failed", url)

def from_domain({:unavailable, :asset_storage}, url),
  do: new(503, "Service unavailable", url)
```

Map duplicate names/tags and invalid fields to `422`, state/tag conflicts to `409`, private masking to `404`, and known storage/readiness failures to `503`. Do not include the safe internal atom in the response body.

- [ ] **Step 6: Check in literal fixtures and run the metadata/contract tests**

Serialize the literal maps from Step 1 with `JSON.encode!/1` in a one-off `mix run` expression, inspect each file, and check in the exact output. The test itself must only read and compare fixtures; it must never regenerate expectations.

Run:

```bash
mix format apps/fornacast_api/mix.exs apps/fornacast_api/lib apps/fornacast_api/test/release_controller_test.exs apps/fornacast_api/test/release_contract_test.exs
mix test apps/fornacast_api/test/release_controller_test.exs apps/fornacast_api/test/release_contract_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

Expected: PASS for both API versions, route ordering, visibility, scopes, pagination, literal fixtures, pinned schemas, URLs, validation, errors, and implemented-through marker `5`.

- [ ] **Step 7: Commit the release metadata API**

```bash
git add apps/fornacast_api/mix.exs apps/fornacast_api/lib/fornacast_api/router.ex apps/fornacast_api/lib/fornacast_api/error.ex apps/fornacast_api/lib/fornacast_api/url.ex apps/fornacast_api/lib/fornacast_api/controllers/release_controller.ex apps/fornacast_api/lib/fornacast_api/controllers/release_asset_controller.ex apps/fornacast_api/lib/fornacast_api/validators apps/fornacast_api/lib/fornacast_api/serializer.ex apps/fornacast_api/lib/fornacast_api/serializers apps/fornacast_api/priv/openapi apps/fornacast_api/test/release_controller_test.exs apps/fornacast_api/test/release_contract_test.exs apps/fornacast_api/test/fixtures
git commit -m "feat(api): expose compatible release metadata"
```

### Task 2: Stream raw uploads and downloads through opaque reader state

**Files:**

- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/plugs/authentication.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/plugs/request_context.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/controllers/health_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/upload_reader.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/controllers/release_asset_controller.ex`
- Modify: `apps/fornacast_api/test/endpoint_test.exs`
- Modify: `apps/fornacast_api/test/authentication_test.exs`
- Modify: `apps/fornacast_api/test/support/conn_case.ex`
- Create: `apps/fornacast_api/test/support/scripted_conn_adapter.ex`
- Create: `apps/fornacast_api/test/release_asset_stream_test.exs`
- Modify: `apps/fornacast_web/mix.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/health_controller.ex`
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Write the failing raw stream and credential-redaction tests**

Add a deterministic adapter whose read script contains `{:more, binary}`, `{:ok, binary}`, `{:error, :timeout}`, `{:error, :closed}`, or `{:raise, exception}` entries. It must delegate response callbacks to `Plug.Adapters.Test.Conn` while sending `{:request_body_read, byte_size(chunk)}` to the test process. Its body callback has this exact contract:

```elixir
@impl Plug.Conn.Adapter
def read_req_body(%{reads: [entry | rest]} = state, _opts) do
  case entry do
    {:more, chunk} ->
      send(state.owner, {:request_body_read, byte_size(chunk)})
      {:more, chunk, %{state | reads: rest}}

    {:ok, chunk} ->
      send(state.owner, {:request_body_read, byte_size(chunk)})
      {:ok, chunk, %{state | reads: rest}}

    {:error, reason} ->
      {:error, reason}

    {:raise, exception} ->
      raise exception
  end
end
```

Cover all of these cases in `release_asset_stream_test.exs`:

```elixir
@stream_cases [
  {:chunked_success, [{:more, "abc"}, {:ok, "def"}], 201},
  {:empty_success, [{:ok, ""}], 201},
  {:timeout, [{:more, "abc"}, {:error, :timeout}], 408},
  {:disconnect, [{:more, "abc"}, {:error, :closed}], 503},
  {:one_byte_overflow, [{:more, "1234"}, {:ok, "5"}], 413}
]

test "authorization and quota admission precede the first body read", %{conn: conn} do
  conn = raw_upload(conn, private_repository_without_access(), [{:ok, "secret bytes"}])
  assert conn.status == 404
  refute_received {:request_body_read, _}
end

test "reader state contains no credentials or authorization data", %{conn: conn} do
  conn =
    conn
    |> put_req_header("cookie", "session=must-not-cross")
    |> put_req_header("proxy-authorization", "Bearer must-not-cross")
    |> authorized_raw_upload_conn([{:ok, "asset"}])

  assert conn.status == 201
  assert_receive {:reader_state_surface,
                  %{
                    assign_keys: [],
                    req_headers: [],
                    private_keys: [],
                    cookies: %{},
                    req_cookies: %{},
                    secret_key_base?: false
                  }}
  assert_receive {:reader_state_inspected, inspected}
  refute inspected =~ "authorization"
  refute inspected =~ "fc_pat_"
  refute inspected =~ "token_hash"
end

test "stream owns compensation and the controller never aborts after entry", %{conn: conn} do
  conn = raw_upload(conn, [{:more, "partial"}, {:error, :closed}])
  assert conn.status == 503
  assert compensation_count(conn.assigns.operation_id) == 1
  assert abort_call_count(conn.assigns.operation_id) == 0
end
```

Extend `authentication_test.exs` so its shared `assert_bad_credentials/2`
helper also asserts `get_req_header(conn, "authorization") == []`. That one
assertion covers malformed, invalid, expired, revoked, and duplicate-header
failures already routed through the helper. Add the same empty-header assertion
to the successful PAT case. The returned connection and endpoint telemetry must
therefore retain no credential header on any authentication outcome.

Also prove malformed, negative, multiple, exact-cap, and cap-plus-one `Content-Length`; an operator-configured lower cap; duplicate name/quota rejection without reads; 30-second idle and 30-minute absolute deadlines under a frozen monotonic clock; content type normalization; no JSON parser invocation; final connection-state threading; a reader exception; successful one-pass digest/size; default JSON GET; binary GET; 1 MiB read clamping; disconnect/no download increment; two completed downloads incrementing twice; safe `Content-Disposition`; and no path/ESS value in responses.
For every failure after repository visibility is known—including insufficient
scope, missing release, malformed length, duplicate name, and quota—assert the
exact `X-Accepted-OAuth-Scopes` value. Authentication/repository-masking
failures that occur before visibility is known retain the empty accepted-scope
header.

- [ ] **Step 2: Run the stream tests and verify the raw adapter is absent**

Run:

```bash
mix test apps/fornacast_api/test/release_asset_stream_test.exs --max-cases 1
```

Expected: FAIL because `POST /api/uploads/repos/:owner/:repo/releases/:release_id/assets` reaches the catch-all, `UploadReader` is absent, and the default media plug rejects the declared asset media type.

- [ ] **Step 3: Consume credentials and implement the opaque Plug reader**

On successful PAT authentication, remove the request header immediately and preserve only the sorted enabled scope names needed by response headers:

```elixir
def call(conn, _opts) do
  case get_req_header(conn, "authorization") do
    [] -> conn
    [authorization] -> authenticate(conn, authorization)
    _headers -> conn |> delete_req_header("authorization") |> bad_credentials()
  end
end

defp authenticate(conn, authorization) do
  with [secret] <- Regex.run(@authorization, authorization, capture: :all_but_first),
       {:ok, actor, api_key} <- ForgeAccounts.authenticate_api_key(secret) do
    conn
    |> delete_req_header("authorization")
    |> assign(:oauth_scopes, enabled_scope_names(api_key.scopes))
    |> assign(:api_auth, %FornacastAPI.Authentication{actor: actor, api_key: api_key})
  else
    _invalid -> conn |> delete_req_header("authorization") |> bad_credentials()
  end
end

defp enabled_scope_names(scopes) do
  scopes
  |> Enum.flat_map(fn
    {scope, true} when is_binary(scope) -> [scope]
    {_scope, _disabled} -> []
  end)
  |> Enum.sort()
end
```

Change `RequestContext`'s before-send header to use `conn.assigns[:oauth_scopes] || []`, and add:

```elixir
def safe_metadata(conn) do
  conn
  |> metadata()
  |> Map.take([:request_id, :ip_address, :user_agent])
end
```

Implement `FornacastAPI.UploadReader` as the only body-state bridge. Its copied
connection contains only the concrete adapter state needed by
`Plug.Conn.read_body/2`; all request headers, assigns, private data, cookies,
params, and the endpoint secret use the empty `%Plug.Conn{}` defaults. The
controller keeps its original sanitized connection outside the domain reader
and merges back only the latest adapter tuple before sending a response:

```elixir
defmodule FornacastAPI.UploadReader do
  @enforce_keys [:conn]
  defstruct [:conn]

  @opaque t :: %__MODULE__{conn: Plug.Conn.t()}

  @spec new(Plug.Conn.t()) :: t()
  def new(%Plug.Conn{adapter: adapter}) do
    %__MODULE__{conn: %Plug.Conn{adapter: adapter, cookies: %{}, req_cookies: %{}}}
  end

  @spec read(t(), keyword()) ::
          {:more, binary(), t()}
          | {:ok, binary(), t()}
          | {:done, t()}
          | {:error, atom(), t()}
  def read(%__MODULE__{conn: conn}, options) do
    case Plug.Conn.read_body(conn, options) do
      {:more, bytes, conn} -> {:more, bytes, %__MODULE__{conn: conn}}
      {:ok, "", conn} -> {:done, %__MODULE__{conn: conn}}
      {:ok, bytes, conn} -> {:ok, bytes, %__MODULE__{conn: conn}}
      {:error, :timeout} -> {:error, :timeout, %__MODULE__{conn: conn}}
      {:error, _reason} -> {:error, :closed, %__MODULE__{conn: conn}}
    end
  end

  @spec put_adapter(t(), Plug.Conn.t()) :: Plug.Conn.t()
  def put_adapter(%__MODULE__{conn: reader_conn}, %Plug.Conn{} = original) do
    %{original | adapter: reader_conn.adapter}
  end

  @doc false
  def retained_surface(%__MODULE__{conn: conn}) do
    %{
      assign_keys: conn.assigns |> Map.keys() |> Enum.sort(),
      req_headers: conn.req_headers,
      private_keys: conn.private |> Map.keys() |> Enum.sort(),
      cookies: conn.cookies,
      req_cookies: conn.req_cookies,
      secret_key_base?: is_binary(conn.secret_key_base)
    }
  end
end

defimpl Inspect, for: FornacastAPI.UploadReader do
  def inspect(_reader, _opts), do: "#FornacastAPI.UploadReader<redacted>"
end
```

Do not catch exceptions in `UploadReader`; `stream_asset_upload/3` owns reader
exception normalization and compensation, then returns the latest state
according to the Plan 2 contract. The test reader wrapper sends
`{:reader_state_surface, UploadReader.retained_surface(state)}` before the
first read, proving actual retained fields rather than trusting the redacted
`Inspect` implementation. On every success/error return, the controller calls
`UploadReader.put_adapter(latest_state, conn)` before rendering so the concrete
adapter's final body state is threaded without copying credential-bearing
connection fields into the domain state.

- [ ] **Step 4: Add route-specific raw media negotiation**

Recognize only the exact upload route and only `POST`. Parse the declared type with Plug rather than a custom regular expression:

```elixir
defp raw_release_upload?(%Plug.Conn{
       method: "POST",
       path_info: ["api", "uploads", "repos", _owner, _repo, "releases", _id, "assets"]
     }),
     do: true

defp raw_release_upload?(_conn), do: false

defp assign_upload_content_type(conn) do
  case get_req_header(conn, "content-type") do
    [value] ->
      case Plug.Conn.Utils.media_type(value) do
        {:ok, type, subtype, _params} ->
          {:ok, assign(conn, :upload_content_type, String.downcase("#{type}/#{subtype}"))}

        :error ->
          :error
      end

    _missing_or_multiple ->
      :error
  end
end
```

For `GET /api/v3/repos/:owner/:repo/releases/assets/:asset_id`, accept an absent/JSON Accept as metadata and exact `application/octet-stream` as bytes; assign `:release_asset_representation` to `:json` or `:binary`. All other body-bearing routes retain the JSON-only rule. Add the upload route after `pipe_through :api_context` and before the upload catch-all:

```elixir
post "/repos/:owner/:repo/releases/:release_id/assets", ReleaseAssetController, :upload
```

- [ ] **Step 5: Implement reader-driven upload and bounded download actions**

The upload action must parse `Content-Length`, authenticate, resolve and authorize the repository/release, authorize mutation scope, reserve through `begin_asset_upload/5`, and only then construct the reader state. Its ownership boundary is:

```elixir
def upload(conn, %{
      "owner" => owner,
      "repo" => slug,
      "release_id" => release_id
    }) do
  conn = fetch_query_params(conn)

  with {:ok, %FornacastAPI.Authentication{actor: actor, api_key: api_key}} <-
         authenticated(conn),
       {:ok, repository} <-
         ForgeRepos.fetch_authorized_repository(actor, owner, slug, :repository_read) do
    accepted =
      ForgeAccounts.APIScope.accepted_scopes(
        :repository_mutation,
        repository.visibility
      )

    conn = assign(conn, :accepted_scopes, accepted)

    with :ok <-
           ForgeAccounts.APIScope.authorize(
             api_key,
             :repository_mutation,
             repository.visibility
           ),
         {:ok, release_id} <- parse_id(release_id),
         {:ok, release} <- ForgeReleases.get_release(repository, release_id, actor),
         {:ok, declared_size} <-
           content_length(conn, Fornacast.Config.release_asset_max_bytes()),
         attrs <- %{
           name: conn.query_params["name"],
           label: conn.query_params["label"],
           content_type: conn.assigns.upload_content_type,
           declared_size: declared_size
         },
         {:ok, upload} <-
           ForgeReleases.begin_asset_upload(
             repository,
             release,
             attrs,
             actor,
             FornacastAPI.Plugs.RequestContext.safe_metadata(conn)
           ) do
      state = FornacastAPI.UploadReader.new(conn)

      case ForgeReleases.stream_asset_upload(
             upload,
             &FornacastAPI.UploadReader.read/2,
             state
           ) do
        {:ok, asset, state} ->
          FornacastAPI.UploadReader.put_adapter(state, conn)
          |> FornacastAPI.Response.json(
            201,
            FornacastAPI.Serializer.render(
              conn.assigns.api_version,
              :release_asset,
              asset,
              owner: owner,
              repo: slug
            ),
            accepted_scopes: accepted
          )

        {:error, reason, state} ->
          FornacastAPI.UploadReader.put_adapter(state, conn)
          |> render_error(reason, @upload_documentation_url, accepted)
      end
    else
      {:error, reason} -> render_error(conn, reason, @upload_documentation_url, accepted)
    end
  else
    {:error, reason} -> render_error(conn, reason, @upload_documentation_url, [])
  end
end
```

The nested `with` is intentional: once repository visibility is known, assign
and preserve `accepted` before scope authorization or any later validation, so
all downstream errors render the same accepted-scope header as success.

`content_length/2` returns `{:ok, nil}` when absent, rejects multiple/malformed/negative values as `400`, and returns `{:error, {:payload_too_large, :asset}}` above the configured effective cap. `parse_id/1` returns `{:ok, positive_integer}` or `{:error, :not_found}`; client IDs never raise.

The controller never calls `abort_asset_upload/2` after entering `stream_asset_upload/3`. A pre-stream failure after reservation, if a later implementation adds one, must call abort exactly once before entering stream.

For binary GET, obtain `open_asset/3`, set the safe metadata headers, call `send_chunked(conn, 200)`, and enumerate a resource that owns the latest opaque handle:

```elixir
defp download_stream(download) do
  Stream.resource(
    fn -> download end,
    fn handle ->
      case ForgeReleases.read_asset_chunk(handle, 1_048_576) do
        {:ok, bytes, next} -> {[{:bytes, bytes}], next}
        :eof -> {[{:eof}], {:done, handle}}
        {:error, reason} -> {[{:error, reason}], {:done, handle}}
      end
    end,
    fn
      {:done, handle} -> ForgeReleases.close_asset_download(handle)
      handle -> ForgeReleases.close_asset_download(handle)
    end
  )
end

defp send_download(conn, repository, asset, download) do
  metadata = ForgeReleases.asset_download_metadata(download)

  conn =
    conn
    |> put_resp_content_type("application/octet-stream")
    |> put_resp_header("content-disposition", metadata.disposition)
    |> send_chunked(200)

  {conn, completed?} =
    Enum.reduce_while(download_stream(download), {conn, false}, fn
      {:bytes, bytes}, {conn, false} ->
        case chunk(conn, bytes) do
          {:ok, conn} -> {:cont, {conn, false}}
          {:error, _closed} -> {:halt, {conn, false}}
        end

      {:eof}, {conn, false} ->
        {:halt, {conn, true}}

      {:error, _reason}, {conn, false} ->
        {:halt, {conn, false}}
    end)

  if completed? do
    case ForgeReleases.record_download(repository, asset) do
      :ok ->
        :ok

      {:error, _reason} ->
        :telemetry.execute(
          [:fornacast, :release_assets, :download_count, :error],
          %{failures: 1},
          %{}
        )
    end
  end

  conn
end
```

No controller receives a path or calls `send_file`. `metadata.size` remains an
internal completion bound; do not combine a `Content-Length` header with
`send_chunked/2`. `Stream.resource/3` advances its resource state to `next`
before yielding each chunk, so its finalizer receives and closes the latest
handle on EOF, reducer halt, or exception.
Once the chunked response has completed, a download-count write failure cannot
replace the already-sent response or crash the request process; emit only the
aggregate safe telemetry event above and leave reconciliation to operations.

- [ ] **Step 6: Add release-asset readiness to both existing health endpoints**

First extend the existing health assertions in `endpoint_test.exs` and
`fornacast_web_test.exs`. The normal response must include
`"release_asset_storage" => "ok"`. Then, in each test file, temporarily set
only the manager's published status to `{:not_ready, :health_test}` with
`:sys.replace_state/2`, restore the prior status in `after`, and assert all of
these outcomes while the test remains synchronous:

```elixir
assert %{
         "status" => "degraded",
         "checks" => %{"release_asset_storage" => "error"}
       } = get(build_conn(), "/health") |> json_response(503)
```

- In `endpoint_test.exs`, create a public `alice/health-repo` fixture before
  changing the status. While `/health` is `503`, assert both
  `GET /api/v3/versions` and `GET /api/v3/repos/alice/health-repo` still return
  `200` with the normal API user-agent header.
- In `fornacast_web_test.exs`, create the same empty public repository under
  the test's temporary repository root. While `/health` is `503`, assert
  `GET /alice/health-repo` still renders `200`.
- After restoring the prior manager status, assert each `/health` endpoint is
  back to `200` and reports `"release_asset_storage" => "ok"`.

Run the two focused tests before changing the controllers:

```bash
mix test apps/fornacast_api/test/endpoint_test.exs \
  apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected red result: both normal health maps omit `release_asset_storage`, and
forcing the manager not-ready does not change either health status.

Add `{:forge_releases, in_umbrella: true}` to `apps/fornacast_web/mix.exs`.
Refactor each existing controller's local `checks` map into a public,
`@doc false` `health_checks/0` function so the released runtime gate can inspect
the same code path. Add this entry without changing either controller's
existing status predicate:

```elixir
checks = Map.put(checks, :release_asset_storage, release_asset_storage_check())
```

Implement the check identically in both controllers:

```elixir
defp release_asset_storage_check do
  if ForgeReleases.AssetStorage.ready?(), do: :ok, else: :error
end
```

`forge_releases` is an enabled permanent application in this delivery slice,
so this check never returns `:disabled`. The API controller must continue to
require every check to equal `:ok`; the web controller must continue to accept
only `:ok` or `:disabled` so disabled SSH remains healthy. In both cases an
enabled not-ready asset store therefore yields HTTP `503`, while no supervisor
or unrelated endpoint is stopped.

Run:

```bash
mix format apps/fornacast_api/lib/fornacast_api/controllers/health_controller.ex \
  apps/fornacast_api/test/endpoint_test.exs \
  apps/fornacast_web/mix.exs \
  apps/fornacast_web/lib/fornacast_web/controllers/health_controller.ex \
  apps/fornacast_web/test/fornacast_web_test.exs
mix test apps/fornacast_api/test/endpoint_test.exs \
  apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: PASS; both endpoints are ready at `200`, become degraded at `503`
for the injected not-ready status, recover to `200`, and the API/repository
requests stay live throughout.

- [ ] **Step 7: Run the stream, metadata, health, and domain boundary tests**

Run:

```bash
mix format apps/fornacast_api/lib apps/fornacast_api/test/support \
  apps/fornacast_api/test/authentication_test.exs \
  apps/fornacast_api/test/release_asset_stream_test.exs
mix test apps/forge_releases/test \
  apps/fornacast_api/test/authentication_test.exs \
  apps/fornacast_api/test/endpoint_test.exs \
  apps/fornacast_api/test/release_controller_test.exs \
  apps/fornacast_api/test/release_asset_stream_test.exs \
  apps/fornacast_api/test/release_contract_test.exs \
  apps/fornacast_web/test/fornacast_web_test.exs \
  --max-cases 1
```

Expected: PASS for auth-before-read, exact cap/lower cap, reader state redaction, one-pass upload, exact-once compensation, timeouts, disconnects, binary download, safe headers, download counting, LocalCAS readiness errors, and all metadata behavior.

- [ ] **Step 8: Commit the raw stream and health adapters**

```bash
git add apps/fornacast_api/lib/fornacast_api/router.ex \
  apps/fornacast_api/lib/fornacast_api/plugs/authentication.ex \
  apps/fornacast_api/lib/fornacast_api/plugs/request_context.ex \
  apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex \
  apps/fornacast_api/lib/fornacast_api/controllers/health_controller.ex \
  apps/fornacast_api/lib/fornacast_api/upload_reader.ex \
  apps/fornacast_api/lib/fornacast_api/controllers/release_asset_controller.ex \
  apps/fornacast_api/test/authentication_test.exs \
  apps/fornacast_api/test/endpoint_test.exs \
  apps/fornacast_api/test/support \
  apps/fornacast_api/test/release_asset_stream_test.exs \
  apps/fornacast_web/mix.exs \
  apps/fornacast_web/lib/fornacast_web/controllers/health_controller.ex \
  apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(api): stream release assets and report storage health"
```

### Task 3: Add real Octokit, `gh api`, and Git client workflows

**Files:**

- Create: `apps/fornacast_api/test/github_workflow_acceptance_test.exs`
- Create: `scripts/github-api-acceptance/package.json`
- Create: `scripts/github-api-acceptance/provision.exs`
- Create: `scripts/github-api-acceptance/octokit-workflow.mjs`
- Create: `scripts/github-api-acceptance/gh-workflow.sh`
- Modify: `package.json`
- Modify: `package-lock.json`

- [ ] **Step 1: Write failing acceptance-artifact and provisioner tests**

The ExUnit test must use `FornacastAPI.ConnCase` so every invocation resets the
database tables before provisioning, assert one ordinary active user receives
one classic PAT with exactly `repo` and `write:org`, and prove only the
caller-visible raw secret reaches a mode-0600 file. It must also syntax-check
both client scripts and reject accidental credential logging:

```elixir
defmodule FornacastAPI.GitHubWorkflowAcceptanceTest do
  use FornacastAPI.ConnCase, async: false

  @scripts Path.expand("../../../scripts/github-api-acceptance", __DIR__)

  @tag :tmp_dir
  test "provisioner writes one scoped secret without printing it", %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    token_path = Path.join(directory, "token")

    ExUnit.CaptureIO.capture_io(fn ->
      Code.eval_file(Path.join(@scripts, "provision.exs"))
      FornacastAcceptance.Provision.run(token_path)
    end)
    |> then(&assert(&1 == ""))

    assert {:ok, %File.Stat{mode: mode}} = File.stat(token_path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert String.starts_with?(File.read!(token_path), "fc_pat_")

    alice = ForgeAccounts.get_user_by_username("alice")
    [key] = ForgeAccounts.list_user_api_keys(alice)
    assert key.name == "github-api-acceptance"
    assert enabled_scopes(key.scopes) == ["repo", "write:org"]
  end

  test "checked-in clients parse and never echo the token" do
    {_, 0} = System.cmd("node", ["--check", Path.join(@scripts, "octokit-workflow.mjs")])
    {_, 0} = System.cmd("bash", ["-n", Path.join(@scripts, "gh-workflow.sh")])

    for filename <- ["octokit-workflow.mjs", "gh-workflow.sh"] do
      source = File.read!(Path.join(@scripts, filename))
      refute source =~ ~r/(set -x|console\.log\([^\n]*token|echo [^\n]*TOKEN)/i
    end
  end

  defp enabled_scopes(scopes) do
    scopes
    |> Enum.flat_map(fn {scope, enabled?} -> if enabled?, do: [scope], else: [] end)
    |> Enum.sort()
  end
end
```

- [ ] **Step 2: Run the acceptance test and verify the artifacts are absent**

Run:

```bash
mix test apps/fornacast_api/test/github_workflow_acceptance_test.exs --max-cases 1
```

Expected: FAIL because the provisioner and client scripts do not exist.

- [ ] **Step 3: Add the isolated npm workspace and deterministic provisioner**

Extend the root workspace list without changing the existing app workspace:

```json
{
  "private": true,
  "workspaces": ["apps/*", "scripts/github-api-acceptance"]
}
```

Create the acceptance package:

```json
{
  "name": "@fornacast/github-api-acceptance",
  "private": true,
  "type": "module",
  "dependencies": {
    "@octokit/rest": "22.0.0"
  }
}
```

Use this verified exact version and run:

```bash
npm install --package-lock-only
npm ci
```

Create `provision.exs` with no output and public context calls only. It accepts
the already-validated destination path as a function argument so the same code
can run in-process in ExUnit and through release RPC:

```elixir
defmodule FornacastAcceptance.Provision do
  def run(token_file) when is_binary(token_file) do
    {:ok, %File.Stat{type: :directory, mode: parent_mode}} =
      token_file |> Path.dirname() |> File.stat()

    true = Bitwise.band(parent_mode, 0o077) == 0
    admin_password = random_password()
    user_password = random_password()

    {:ok, site_admin} =
      ForgeAccounts.create_first_admin(%{
        username: "siteadmin",
        email: "siteadmin@example.test",
        password: admin_password
      })

    Fornacast.Setup.mark_initialized!(site_admin)

    {:ok, alice} =
      ForgeAccounts.create_user(%{
        username: "alice",
        email: "alice@example.test",
        password: user_password
      })

    {:ok, _api_key, secret} =
      ForgeAccounts.create_api_key(alice, %{
        name: "github-api-acceptance",
        scopes: ["repo", "write:org"]
      })

    {:ok, io} = File.open(token_file, [:write, :exclusive, :binary])

    try do
      :ok = File.chmod(token_file, 0o600)
      :ok = IO.binwrite(io, secret)
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end

  defp random_password do
    "acceptance-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
```

The production acceptance directory is disposable, so fixed usernames are intentional. The raw secret is never returned from a REST endpoint.

- [ ] **Step 4: Implement the complete Octokit workflow**

`octokit-workflow.mjs` accepts only these environment variables:

```javascript
import assert from "node:assert/strict";
import {readFileSync, writeFileSync} from "node:fs";
import {Octokit} from "@octokit/rest";

async function main() {
const origin = required("FORNACAST_PUBLIC_ORIGIN").replace(/\/$/, "");
const token = readFileSync(required("FORNACAST_ACCEPTANCE_TOKEN_FILE"), "utf8").trim();
const statePath = required("FORNACAST_ACCEPTANCE_STATE_FILE");
const suffix = required("FORNACAST_ACCEPTANCE_SUFFIX");

const client = new Octokit({
  auth: token,
  baseUrl: `${origin}/api/v3`,
  userAgent: "fornacast-octokit-acceptance/1.0"
});
```

Implement these exact ordered calls and assertions:

```javascript
const user = (await client.request("GET /user")).data;
assert.equal(user.login, "alice");

for (const version of ["2022-11-28", "2026-03-10"]) {
  const response = await client.request("GET /versions", {
    headers: {"x-github-api-version": version}
  });
  assert.deepEqual(response.data, ["2022-11-28", "2026-03-10"]);
  assert.equal(response.headers["x-github-api-version-selected"], version);
}

const owner = `acceptance-${suffix}`;
const repo = `workflow-${suffix}`;

await client.request("POST /admin/organizations", {
  login: owner,
  admin: "alice",
  profile_name: `Acceptance ${suffix}`
});

await client.request("POST /orgs/{org}/repos", {
  org: owner,
  name: repo,
  auto_init: true,
  private: true
});

const main = await client.request("GET /repos/{owner}/{repo}/git/ref/{ref}", {
  owner,
  repo,
  ref: "heads/main"
});

await client.request("POST /repos/{owner}/{repo}/git/refs", {
  owner,
  repo,
  ref: "refs/heads/feature",
  sha: main.data.object.sha
});

const created = await client.request("PUT /repos/{owner}/{repo}/contents/{path}", {
  owner,
  repo,
  path: "acceptance.txt",
  message: "Create acceptance content",
  branch: "feature",
  content: Buffer.from("first\n").toString("base64")
});

await client.request("PUT /repos/{owner}/{repo}/contents/{path}", {
  owner,
  repo,
  path: "acceptance.txt",
  message: "Update acceptance content",
  branch: "feature",
  sha: created.data.content.sha,
  content: Buffer.from("second\n").toString("base64")
});

const issue = await client.request("POST /repos/{owner}/{repo}/issues", {
  owner, repo, title: "Acceptance issue", body: "Initial body"
});
await client.request("PATCH /repos/{owner}/{repo}/issues/{issue_number}", {
  owner, repo, issue_number: issue.data.number, title: "Edited acceptance issue"
});
await client.request("POST /repos/{owner}/{repo}/issues/{issue_number}/comments", {
  owner, repo, issue_number: issue.data.number, body: "Acceptance comment"
});
await client.request("PATCH /repos/{owner}/{repo}/issues/{issue_number}", {
  owner, repo, issue_number: issue.data.number, state: "closed"
});
await client.request("PATCH /repos/{owner}/{repo}/issues/{issue_number}", {
  owner, repo, issue_number: issue.data.number, state: "open"
});

const pull = await client.request("POST /repos/{owner}/{repo}/pulls", {
  owner, repo, title: "Acceptance pull", head: "feature", base: "main"
});
const feature = await client.request("GET /repos/{owner}/{repo}/git/ref/{ref}", {
  owner, repo, ref: "heads/feature"
});
const merge = await client.request("PUT /repos/{owner}/{repo}/pulls/{pull_number}/merge", {
  owner, repo, pull_number: pull.data.number, sha: feature.data.object.sha, merge_method: "merge"
});
assert.equal(merge.data.merged, true);

const release = await client.request("POST /repos/{owner}/{repo}/releases", {
  owner, repo, tag_name: `v-${suffix}`, target_commitish: "main",
  name: `Acceptance ${suffix}`, body: "Release acceptance", draft: false, prerelease: false
});

const sharedBytes = Buffer.from("deduplicated release asset\n");
const upload = async (name, bytes) => {
  const url = release.data.upload_url.replace("{?name,label}", `?name=${encodeURIComponent(name)}&label=Linux`);
  return client.request(`POST ${url}`, {
    data: bytes,
    headers: {"content-type": "application/octet-stream", "content-length": String(bytes.length)}
  });
};

const first = await upload("shared-a.bin", sharedBytes);
const second = await upload("shared-b.bin", sharedBytes);
assert.equal(first.data.digest, second.data.digest);

const metadata = await client.request("GET /repos/{owner}/{repo}/releases/assets/{asset_id}", {
  owner, repo, asset_id: second.data.id
});
assert.equal(metadata.data.digest, second.data.digest);

const download = async assetId => client.request(
  "GET /repos/{owner}/{repo}/releases/assets/{asset_id}",
  {owner, repo, asset_id: assetId, headers: {accept: "application/octet-stream"}, request: {parseSuccessResponseBody: false}}
);

assert.deepEqual(Buffer.from((await download(first.data.id)).data), sharedBytes);
await client.request("DELETE /repos/{owner}/{repo}/releases/assets/{asset_id}", {
  owner, repo, asset_id: first.data.id
});
assert.deepEqual(Buffer.from((await download(second.data.id)).data), sharedBytes);
await client.request("DELETE /repos/{owner}/{repo}/releases/assets/{asset_id}", {
  owner, repo, asset_id: second.data.id
});

const retainedBytes = Buffer.from("retained across cold backup\n");
const retained = await upload("retained.bin", retainedBytes);

await client.request("POST /repos/{owner}/{repo}/releases", {
  owner, repo, tag_name: `v-${suffix}-pagination`, target_commitish: "main",
  name: `Pagination ${suffix}`, body: "Second release", draft: false, prerelease: false
});

const page = await client.request("GET /repos/{owner}/{repo}/releases", {
  owner, repo, per_page: 1, page: 1
});
assert.equal(page.data.length, 1);
assert.match(page.headers.link ?? "", /rel="last"|rel="next"/);

const mergeCommit = await client.request("GET /repos/{owner}/{repo}/commits/{ref}", {
  owner, repo, ref: merge.data.sha
});
assert.equal(mergeCommit.data.parents.length, 2);

const state = {
  owner,
  repo,
  tag: release.data.tag_name,
  mergeSha: merge.data.sha,
  gcDigest: second.data.digest.replace(/^sha256:/, ""),
  retainedAssetId: retained.data.id,
  retainedDigest: retained.data.digest,
  retainedBytes: retainedBytes.toString("base64")
};
writeFileSync(statePath, JSON.stringify(state), {mode: 0o600});
}
```

Use these exact helpers and top-level error boundary; never print an Octokit request object:

```javascript
function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`missing ${name}`);
  return value;
}

function assertGitHubHeaders(response, version) {
  assert.equal(response.headers["x-github-api-version-selected"], version);
  assert.ok(response.headers["x-github-request-id"]);
  assert.ok(response.headers["x-ratelimit-limit"]);
  assert.ok(response.headers["x-ratelimit-remaining"]);
  assert.ok(response.headers["x-oauth-scopes"]);
  assert.ok(response.headers["x-accepted-oauth-scopes"] !== undefined);
}

main().catch(error => {
  process.stderr.write(`${error.name}: ${error.message}\n`);
  process.exitCode = 1;
});
```

The script does not delete the namespace because Task 4 needs it for restart, GC, Git, and backup assertions.

- [ ] **Step 5: Implement the same lifecycle with `gh api` and normal Git**

`gh-workflow.sh` uses a different suffix and never enables shell tracing. Configure the enterprise host and token without printing them:

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${FORNACAST_PUBLIC_ORIGIN:?required}"
: "${FORNACAST_ACCEPTANCE_TOKEN_FILE:?required}"
: "${FORNACAST_ACCEPTANCE_SUFFIX:?required}"

origin_authority="${FORNACAST_PUBLIC_ORIGIN#*://}"
export GH_HOST="${origin_authority%%:*}"
export GH_ENTERPRISE_TOKEN="$(<"$FORNACAST_ACCEPTANCE_TOKEN_FILE")"
api_version="2026-03-10"
owner="gh-${FORNACAST_ACCEPTANCE_SUFFIX}"
repo="workflow-${FORNACAST_ACCEPTANCE_SUFFIX}"
api_root="${FORNACAST_PUBLIC_ORIGIN}/api/v3"
work_dir="$(mktemp -d)"

cleanup() {
  rm -rf -- "$work_dir"
  unset GH_ENTERPRISE_TOKEN
}
trap cleanup EXIT

gh_api() {
  local -a args=("$@")
  local found=false

  for index in "${!args[@]}"; do
    case "${args[$index]}" in
      /*)
        args[$index]="${api_root}${args[$index]}"
        found=true
        break
        ;;
    esac
  done

  test "$found" = true
  gh api --hostname "$GH_HOST" -H "X-GitHub-Api-Version: $api_version" "${args[@]}"
}

test "$(gh_api /user --jq .login)" = "alice"
gh_api --method POST /admin/organizations -f login="$owner" -f admin=alice -f profile_name="GH acceptance"
gh_api --method POST "/orgs/$owner/repos" -f name="$repo" -F auto_init=true -F private=true

main_sha="$(gh_api "/repos/$owner/$repo/git/ref/heads/main" --jq .object.sha)"
gh_api --method POST "/repos/$owner/$repo/git/refs" -f ref=refs/heads/feature -f sha="$main_sha"

first_content="$(printf 'first\n' | base64 | tr -d '\n')"
created="$(gh_api --method PUT "/repos/$owner/$repo/contents/acceptance.txt" \
  -f message='Create acceptance content' -f branch=feature -f content="$first_content")"
content_sha="$(printf '%s' "$created" | jq -r .content.sha)"
second_content="$(printf 'second\n' | base64 | tr -d '\n')"
gh_api --method PUT "/repos/$owner/$repo/contents/acceptance.txt" \
  -f message='Update acceptance content' -f branch=feature -f sha="$content_sha" -f content="$second_content" >/dev/null

issue_number="$(gh_api --method POST "/repos/$owner/$repo/issues" -f title='Acceptance issue' -f body='Initial body' --jq .number)"
gh_api --method PATCH "/repos/$owner/$repo/issues/$issue_number" -f title='Edited acceptance issue' >/dev/null
gh_api --method POST "/repos/$owner/$repo/issues/$issue_number/comments" -f body='Acceptance comment' >/dev/null
gh_api --method PATCH "/repos/$owner/$repo/issues/$issue_number" -f state=closed >/dev/null
gh_api --method PATCH "/repos/$owner/$repo/issues/$issue_number" -f state=open >/dev/null

pull_number="$(gh_api --method POST "/repos/$owner/$repo/pulls" -f title='Acceptance pull' -f head=feature -f base=main --jq .number)"
feature_sha="$(gh_api "/repos/$owner/$repo/git/ref/heads/feature" --jq .object.sha)"
merge_sha="$(gh_api --method PUT "/repos/$owner/$repo/pulls/$pull_number/merge" -f sha="$feature_sha" -f merge_method=merge --jq .sha)"
test "$(gh_api "/repos/$owner/$repo/commits/$merge_sha" --jq '.parents | length')" = 2

release="$(gh_api --method POST "/repos/$owner/$repo/releases" \
  -f tag_name="v-${FORNACAST_ACCEPTANCE_SUFFIX}" -f target_commitish=main \
  -f name='GH acceptance' -f body='Release acceptance' -F draft=false -F prerelease=false)"
upload_url="$(printf '%s' "$release" | jq -r .upload_url | sed 's/{?name,label}//')"
asset_file="$work_dir/asset.bin"
download_file="$work_dir/download.bin"
clone_dir="$work_dir/clone"
printf 'gh release asset\n' > "$asset_file"
asset="$(gh api --hostname "$GH_HOST" --method POST \
  -H "X-GitHub-Api-Version: $api_version" -H 'Content-Type: application/octet-stream' \
  --input "$asset_file" "${upload_url}?name=gh-asset.bin&label=Linux")"
asset_id="$(printf '%s' "$asset" | jq -r .id)"
gh_api "/repos/$owner/$repo/releases/assets/$asset_id" --jq '.state == "uploaded"' | grep -qx true
gh_api -H 'Accept: application/octet-stream' \
  "/repos/$owner/$repo/releases/assets/$asset_id" > "$download_file"
cmp "$asset_file" "$download_file"

askpass="$work_dir/askpass"
printf '%s\n' \
  '#!/bin/sh' \
  'case "$1" in' \
  '  *Username*) printf "%s" alice ;;' \
  '  *) printf "%s" "$GH_ENTERPRISE_TOKEN" ;;' \
  'esac' > "$askpass"
chmod 700 "$askpass"
GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git clone \
  "${FORNACAST_PUBLIC_ORIGIN}/${owner}/${repo}.git" "$clone_dir"
git -C "$clone_dir" fetch --tags
test "$(git -C "$clone_dir" rev-list --parents -n 1 "$merge_sha" | wc -w)" -eq 3
git -C "$clone_dir" rev-parse "v-${FORNACAST_ACCEPTANCE_SUFFIX}^{commit}" >/dev/null
```

`GH_HOST` is deliberately the hostname only; GitHub CLI rejects an authority
containing a port. `gh_api` rewrites each API path to an absolute HTTP URL at
the isolated public origin, so `gh` neither assumes HTTPS nor prepends a second
`/api/v3`. The checked-in test invokes `gh api --hostname 127.0.0.1` with an
absolute local URL and fails if a later edit regresses either rule.

Add negative assertions for account-password Git auth, legacy read-only mutation denial, revoked/expired tokens, private `404` masking, stale content SHA, ref race, duplicate asset name, and oversized declared length. Each assertion checks the exact status and GitHub-shaped message without printing a credential.

- [ ] **Step 6: Run syntax, provisioner, and lockfile checks**

Run:

```bash
npm ci
node --check scripts/github-api-acceptance/octokit-workflow.mjs
bash -n scripts/github-api-acceptance/gh-workflow.sh
mix test apps/fornacast_api/test/github_workflow_acceptance_test.exs --max-cases 1
git diff --check
```

Expected: PASS; `package-lock.json` contains one exact Octokit graph, both scripts parse, the fixture provisions exactly the approved scopes, and no test output contains the raw PAT.

- [ ] **Step 7: Commit the client workflows**

```bash
git add apps/fornacast_api/test/github_workflow_acceptance_test.exs scripts/github-api-acceptance/package.json scripts/github-api-acceptance/provision.exs scripts/github-api-acceptance/octokit-workflow.mjs scripts/github-api-acceptance/gh-workflow.sh package.json package-lock.json
git commit -m "test(api): add GitHub release client workflows"
```

### Task 4: Prove the released Docker system, delayed GC, and cold restore

**Files:**

- Create: `scripts/github-api-acceptance/runtime-gate.exs`
- Create: `scripts/github-api-acceptance/docker-storage-gate.sh`
- Create: `scripts/github-api-acceptance/docker-backup-restore-gate.sh`
- Modify: `.github/workflows/e2e.yml`
- Modify: `.dockerignore`
- Modify: `.gitignore`
- Modify: `README.md`

- [ ] **Step 1: Add failing syntax and release-artifact gate tests**

Extend `github_workflow_acceptance_test.exs` so the production scripts are required, parse, and contain all mandatory checks:

```elixir
test "production gates cover runtime, GC, restart, and cold restore" do
  runtime = File.read!(Path.join(@scripts, "runtime-gate.exs"))
  storage = File.read!(Path.join(@scripts, "docker-storage-gate.sh"))
  backup = File.read!(Path.join(@scripts, "docker-backup-restore-gate.sh"))
  e2e = File.read!(Path.expand("../../../.github/workflows/e2e.yml", __DIR__))
  dockerignore = File.read!(Path.expand("../../../.dockerignore", __DIR__))
  gitignore = File.read!(Path.expand("../../../.gitignore", __DIR__))

  [_, release_job_and_after] =
    String.split(e2e, "\n  release-api-storage:\n", parts: 2)

  release_job =
    Regex.split(~r/\n  [a-z0-9_-]+:\n/, release_job_and_after, parts: 2)
    |> hd()

  Code.string_to_quoted!(runtime)
  {_, 0} = System.cmd("bash", ["-n", Path.join(@scripts, "docker-storage-gate.sh")])
  {_, 0} = System.cmd("bash", ["-n", Path.join(@scripts, "docker-backup-restore-gate.sh")])

  for worker <- ~w(multipart_gc content_gc cas_gc packer lifecycle cross_cluster_replication repair scrub) do
    assert runtime =~ worker
  end

  assert runtime =~ "Application.spec(:ex_storage_service_s3)"
  assert runtime =~ "ExStorageServiceS3.Application"
  assert runtime =~ "ForgeReleases.BlobGC.run_once"
  assert runtime =~ "ForgeReleases.IntegrityAudit.run"
  assert runtime =~ "ForgeReleases.StorageTelemetry.snapshot"
  assert runtime =~ "release_asset_storage"
  assert runtime =~ "restart-storage"
  assert runtime =~ "hold-storage-not-ready"
  assert runtime =~ ":acceptance_barrier"
  assert storage =~ "503"
  assert storage =~ "Accept: application/octet-stream"
  assert storage =~ "LC_ALL=C sort -u"
  assert storage =~ "refusing concurrent release acceptance"
  assert storage =~ "refusing to reuse pre-existing acceptance volume"
  assert storage =~ "fornacast-release-e2e-lock"
  assert storage =~ "docker create"
  assert storage =~ "fornacast.release-e2e.owner"
  assert storage =~ "set -euo pipefail\numask 077"
  refute storage =~ ".gate-lock"
  assert storage =~ "COMPOSE_DISABLE_ENV_FILE=1"
  assert storage =~ "unset COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES"
  assert storage =~ ~s(--project-directory "$repo_root")
  assert storage =~ ~s(-f "$compose_file")
  assert storage =~ ~s(--project-name "$COMPOSE_PROJECT_NAME")
  assert storage =~ ~s(--env-file "$compose_env")
  assert storage =~ ~s(export FORNACAST_DATABASE_ADAPTER="turso")
  assert storage =~ ~s(export FORNACAST_DATABASE_PATH="/data/fornacast.db")
  assert storage =~ ~s(export FORNACAST_CONFIG_DATABASE_PATH="/data/fornacast_config.db")
  assert storage =~ ~s(export FORNACAST_SSH_HOST="localhost")
  assert storage =~ ~s(export TURSO_DATABASE_URL="")
  assert storage =~ ~s(export DATABASE_URL="")
  assert length(Regex.scan(~r/docker compose/, storage)) == 1
  assert storage =~ "owns_artifacts"
  assert storage =~ "ensure_safe_directory"
  assert storage =~ "reject_symlink"
  assert storage =~ ~s([ ! -O "$path" ])
  assert storage =~ "fornacast-release-e2e-unused"
  assert storage =~ "FORNACAST_ACCEPTANCE_VOLUME_MARKER"
  {lock_at, _} = :binary.match(storage, "if ! docker create")
  {artifacts_at, _} = :binary.match(storage, ~s(ensure_safe_directory "$acceptance_dir"))
  assert lock_at < artifacts_at
  assert storage =~ "compose stop -t 45 app"
  assert storage =~ ~s({{.State.ExitCode}})
  assert storage =~ ~s({{.State.OOMKilled}})
  assert storage =~ "compose start app"
  refute storage =~ "compose restart app"
  refute storage =~ "compose down --volumes"
  assert storage =~ ~s(docker volume rm "$volume")
  assert storage =~ ~s(.status == "degraded" and .checks.release_asset_storage == "error")
  assert storage =~ ~s(.checks.release_asset_storage == "ok")
  assert storage =~ "rm -f /data/github-api-acceptance/token"
  assert storage =~ "test ! -e /data/github-api-acceptance/token"
  assert storage =~ ~s(rm -f -- "$token_file" "$curl_config")
  assert storage =~ "docker-backup-restore-gate.sh"
  assert backup =~ ~s(rm -f -- "$curl_config")
  assert backup =~ "compose stop -t 45 app"
  assert backup =~ "compose up -d --force-recreate --no-deps nginx"
  assert backup =~ "COMPOSE_DISABLE_ENV_FILE=1"
  assert backup =~ ~s(test -O "$acceptance_dir")
  assert backup =~ ~s(--project-directory "$repo_root")
  assert backup =~ ~s(-f "$compose_file")
  assert backup =~ ~s(--project-name "$COMPOSE_PROJECT_NAME")
  assert backup =~ ~s(--env-file "$compose_env")
  assert length(Regex.scan(~r/docker compose/, backup)) == 1
  assert backup =~ ~s({{.State.ExitCode}})
  assert backup =~ "fornacast_config.db"
  assert backup =~ "release-assets/concord"
  assert backup =~ "release-assets/cas"
  assert backup =~ "release-assets/tmp"
  assert backup =~ "assert_owned_volume"
  assert backup =~ "FORNACAST_ACCEPTANCE_VOLUME_MARKER"
  assert backup =~ "fornacast.release-e2e.owner"
  assert backup =~ "set -euo pipefail\numask 077"
  assert backup =~ ~s(.checks.release_asset_storage == "ok")
  assert "e2e-data" in String.split(dockerignore, "\n")
  assert "/e2e-data/" in String.split(gitignore, "\n")
  assert e2e =~ ~s(FORNACAST_SSH_PORT: "2222")
  assert e2e =~ "POSTGRES_PASSWORD: fornacast-release-e2e-unused"
  assert release_job =~ "SECRET_KEY_BASE=\"$(openssl rand -base64 48)\" \\"
  refute release_job =~ "$GITHUB_ENV"
  refute release_job =~ ~r/^      SECRET_KEY_BASE:/m
  refute e2e =~ "docker compose down --volumes"
end
```

Run:

```bash
mix test apps/fornacast_api/test/github_workflow_acceptance_test.exs --max-cases 1
```

Expected: FAIL because the three production gate scripts do not exist.

- [ ] **Step 2: Implement runtime inspection, repeated ESS restart, and deterministic GC**

Create `runtime-gate.exs`. It is loaded through `rpc` into the running released
BEAM and supports exactly `inspect`, `restart-storage`,
`hold-storage-not-ready`, and `gc` calls. Mode and validated GC values are
explicit function arguments; do not attempt to pass them through the
environment of the short-lived RPC client:

```elixir
defmodule FornacastAcceptance.RuntimeGate do
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

  @optional_child_ids [
    ExStorageService.Storage.MultipartGC,
    ExStorageService.Storage.ContentGC,
    ExStorageService.Storage.CasGC,
    ExStorageService.Storage.Packer,
    ExStorageService.Storage.Lifecycle,
    ExStorageService.Cluster.Outbox.Supervisor
  ]

  def run("inspect") do
    {:ok, config} = ExStorageService.InstanceConfig.from_application_env()
    :fornacast_release_assets = config.instance
    false = config.auto_start
    false = config.web_enabled
    false = config.public_s3_enabled
    false = config.cluster_data_plane_enabled
    true = config.mode == :standalone
    true = config.node_role == :data

    Enum.each(@workers, fn worker ->
      false = ExStorageService.InstanceConfig.worker_enabled?(config, worker)
    end)

    supervisor = instance_supervisor(config.instance)
    true = is_pid(supervisor)

    child_ids =
      supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    true = ExStorageService.Storage.Engine in child_ids
    [] = Enum.filter(@optional_child_ids, &(&1 in child_ids))
    true = ForgeReleases.AssetStorage.ready?()
    %{release_asset_storage: :ok} = FornacastAPI.HealthController.health_checks()
    %{release_asset_storage: :ok} = FornacastWeb.HealthController.health_checks()

    nil = Application.spec(:ex_storage_service_s3)
    :non_existing = :code.which(ExStorageServiceS3.Application)
    assert_no_storage_listeners!()

    {:ok, report} = ForgeReleases.IntegrityAudit.run(mode: :dry_run, limit: 50)
    0 = report.failures
    0 = report.corrupt
    0 = report.blob_states.corrupt
    nil = report.next_cursor
    [] = report.integrity_failures
    :ok = assert_storage_telemetry!()
    :ok
  end

  def run("restart-storage") do
    {:ok, config} = ExStorageService.InstanceConfig.from_application_env()

    Enum.each(1..8, fn _attempt ->
      previous = instance_supervisor(config.instance)
      true = is_pid(previous)
      Process.exit(previous, :kill)

      :ok = wait_until(fn -> not ForgeReleases.AssetStorage.ready?() end, 10_000)

      :ok =
        wait_until(
          fn ->
            restarted = instance_supervisor(config.instance)
            is_pid(restarted) and restarted != previous and
              ForgeReleases.AssetStorage.ready?()
          end,
          30_000
        )
    end)

    :ok
  end

  def run("hold-storage-not-ready", ready_file, release_file) do
    true = Path.type(ready_file) == :absolute
    true = Path.type(release_file) == :absolute
    false = ready_file == release_file

    manager = Process.whereis(ForgeReleases.AssetStorage.Manager)
    true = is_pid(manager)
    %{status: :ready} = state = :sys.get_state(manager)

    try do
      :sys.replace_state(manager, &Map.put(&1, :status, {:not_ready, :acceptance_barrier}))
      false = ForgeReleases.AssetStorage.ready?()
      :ok = File.write(ready_file, "not-ready\n", [:sync])

      :ok = wait_until(fn -> File.exists?(release_file) end, 60_000)
    after
      :sys.replace_state(manager, &Map.put(&1, :status, state.status))
    end

    :ok = wait_until(&ForgeReleases.AssetStorage.ready?/0, 30_000)
  end

  def run("gc", digest, phase) do
    true = Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
    grace = Fornacast.Config.release_asset_gc_grace_seconds()
    now = DateTime.utc_now()

    case phase do
      "candidate" ->
        {:ok, %{next_due_cursor: nil}} = ForgeReleases.BlobGC.run_once(now: now)

      "delete" ->
        {:ok, %{next_due_cursor: nil}} =
          ForgeReleases.BlobGC.run_once(now: DateTime.add(now, grace + 1))
    end

    {:ok, report} = ForgeReleases.IntegrityAudit.run(mode: :dry_run, limit: 50)
    expected_state = if phase == "candidate", do: :candidate, else: :absent
    %{state: ^expected_state} = Enum.find(report.blobs, &(&1.digest == digest))
    0 = report.failures
    0 = report.corrupt
    0 = report.blob_states.corrupt
    nil = report.next_cursor
    [] = report.integrity_failures
    :ok
  end

  defp instance_supervisor(instance) do
    instance
    |> ExStorageService.Names.instance_supervisor()
    |> GenServer.whereis()
  end

  defp assert_storage_telemetry! do
    {:ok,
     snapshot = %{
       capacity: capacity = %{cas: cas, staging: staging},
       operations:
         operations = %{
         upload_nonterminal: upload_nonterminal,
         delete_nonterminal: delete_nonterminal
       },
       blob_states:
         blob_states = %{
         absent: absent,
         pending: pending,
         ready: ready,
         candidate: candidate,
         deleting: deleting,
         corrupt: corrupt
       }
     }} = ForgeReleases.StorageTelemetry.snapshot()

    3 = map_size(snapshot)
    2 = map_size(capacity)
    2 = map_size(operations)
    6 = map_size(blob_states)

    Enum.each([cas, staging], fn area ->
      2 = map_size(area)

      Enum.each([area.bytes, area.inodes], fn dimension ->
        5 = map_size(dimension)

        true =
          Enum.all?(
            [dimension.total, dimension.available, dimension.used],
            &(is_integer(&1) and &1 >= 0)
          )

        true = dimension.available <= dimension.total
        expected_used = dimension.total - dimension.available
        ^expected_used = dimension.used
        expected_known = dimension.total > 0
        ^expected_known = dimension.known

        expected_pressure =
          if dimension.known,
            do: div(dimension.used * 10_000, dimension.total),
            else: 0

        ^expected_pressure = dimension.pressure_basis_points
      end)
    end)

    true =
      Enum.all?(
        [
          upload_nonterminal,
          delete_nonterminal,
          absent,
          pending,
          ready,
          candidate,
          deleting,
          corrupt
        ],
        &(is_integer(&1) and &1 >= 0)
      )

    :ok
  end

  defp wait_until(predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(predicate, deadline)
  end

  defp do_wait(predicate, deadline) do
    cond do
      predicate.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> raise "runtime gate timed out"
      true -> Process.sleep(25); do_wait(predicate, deadline)
    end
  end

  defp assert_no_storage_listeners! do
    required =
      ["PORT", "FORNACAST_API_PORT", "FORNACAST_SSH_PORT"]
      |> Enum.map(&System.fetch_env!/1)
      |> Enum.map(&String.to_integer/1)
      |> MapSet.new()

    actual =
      ["/proc/net/tcp", "/proc/net/tcp6"]
      |> Enum.flat_map(&listening_ports/1)
      |> MapSet.new()

    [] = MapSet.difference(required, actual) |> MapSet.to_list() |> Enum.sort()
    [] = MapSet.intersection(actual, MapSet.new([9_000, 9_100])) |> MapSet.to_list()
  end

  defp listening_ports(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [_slot, local, _remote, "0A" | _rest] ->
          [_address, port] = String.split(local, ":", parts: 2)
          [String.to_integer(port, 16)]

        _not_listening ->
          []
      end
    end)
  end
end
```

This script deliberately inspects both configuration and the live instance
supervisor. `repair`, `scrub`, and `cross_cluster_replication` are proved absent
through their false flags plus the missing outbox supervisor. The Linux
listener check requires the configured web, API, and SSH ports and rejects the
ESS public/internal ports 9000 and 9100. It deliberately permits EPMD and BEAM
distribution listeners used by the release `rpc` command; the host-side diff
separately proves that only SSH and nginx are published.
`restart-storage` proves eight real death/restart cycles. The separate
`hold-storage-not-ready` acceptance-only RPC uses `:sys.replace_state/2` to
hold the manager's already-public status at a deterministic not-ready barrier
without stopping unrelated request handling; its `after` block always restores
the prior `:ready` value. It neither becomes a product API nor substitutes for
the real restart loop.

- [ ] **Step 3: Implement the public-origin storage and supervision gate**

Create `docker-storage-gate.sh`. It owns an isolated Compose project, records host listeners before startup, starts the checked-in app/nginx stack, provisions the PAT, runs both clients, exercises repeated storage failure, and runs delayed GC:

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

compose_file="$repo_root/docker-compose.yml"
if [ ! -f "$compose_file" ] || [ -L "$compose_file" ]; then
  echo "refusing non-regular Compose file: $compose_file" >&2
  exit 1
fi
export COMPOSE_PROJECT_NAME="fornacast-release-e2e"
export COMPOSE_DISABLE_ENV_FILE=1
export FORNACAST_IMAGE="fornacast-release-e2e:local"
export FORNACAST_DATABASE_ADAPTER="turso"
export FORNACAST_DATABASE_PATH="/data/fornacast.db"
export FORNACAST_CONFIG_DATABASE_PATH="/data/fornacast_config.db"
export TURSO_DATABASE_URL=""
export TURSO_AUTH_TOKEN=""
export FORNACAST_CONFIG_TURSO_DATABASE_URL=""
export FORNACAST_CONFIG_TURSO_AUTH_TOKEN=""
export CONCORD_TURSO_REMOTE_URL=""
export CONCORD_TURSO_AUTH_TOKEN=""
export DATABASE_URL=""
export FORNACAST_BASE_URL="http://127.0.0.1:4000"
export FORNACAST_REPO_STORAGE_ROOT="/data/repos"
export FORNACAST_RELEASE_ASSET_STORAGE_ROOT="/data/release-assets"
export FORNACAST_RELEASE_ASSET_MAX_BYTES="2147483648"
export FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS="86400"
export FORNACAST_SSH_HOST="localhost"
export FORNACAST_SSH_PORT="2222"
export POSTGRES_PASSWORD="fornacast-release-e2e-unused"
unset COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES
: "${SECRET_KEY_BASE:?required}"

artifacts_root="$repo_root/e2e-data"
acceptance_dir="$repo_root/e2e-data/release-api"
token_file="$acceptance_dir/token"
state_file="$acceptance_dir/octokit-state.json"
curl_config="$acceptance_dir/curl.conf"
health_down_file="$acceptance_dir/health-down.json"
compose_log="$acceptance_dir/compose.log"
compose_env="$acceptance_dir/compose.env"
listeners_before="$acceptance_dir/listeners.before"
listeners_after="$acceptance_dir/listeners.after"
listeners_added="$acceptance_dir/listeners.added"
listeners_expected="$acceptance_dir/listeners.expected"
backup_dir="$acceptance_dir/backup"
health_url="$FORNACAST_BASE_URL/health"
volume="${COMPOSE_PROJECT_NAME}_fornacast-data"
owner_marker=".fornacast-release-e2e-owner"
storage_down_ready="/data/github-api-acceptance/storage-down.ready"
storage_down_release="/data/github-api-acceptance/storage-down.release"
run_marker="$(openssl rand -hex 16)"
lock_container="fornacast-release-e2e-lock"
owns_project=false
owns_lock_container=false
owns_artifacts=false

compose() {
  docker compose --project-directory "$repo_root" --env-file "$compose_env" \
    -f "$compose_file" --project-name "$COMPOSE_PROJECT_NAME" "$@"
}

reject_symlink() {
  local path="$1"
  if [ -L "$path" ]; then
    echo "refusing symlinked acceptance path: $path" >&2
    exit 1
  fi
}

ensure_safe_directory() {
  local path="$1"
  reject_symlink "$path"
  if [ -e "$path" ]; then
    if [ ! -d "$path" ]; then
      echo "refusing non-directory acceptance path: $path" >&2
      exit 1
    fi
  else
    mkdir -- "$path"
  fi
  reject_symlink "$path"
  if [ ! -d "$path" ] || [ ! -O "$path" ]; then
    echo "refusing unowned acceptance directory: $path" >&2
    exit 1
  fi
}

prepare_output_file() {
  local path="$1"
  reject_symlink "$path"
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "refusing non-file acceptance output: $path" >&2
    exit 1
  fi
  rm -f -- "$path"
}

owns_volume() {
  [ "$(docker volume inspect -f '{{ index .Labels "fornacast.release-e2e.owner" }}' "$volume" 2>/dev/null || true)" = "$run_marker" ]
}

cleanup() {
  status=$?
  trap - EXIT
  if [ "$owns_project" = true ] && owns_volume; then
    compose exec -T app sh -ceu \
      'mkdir -p /data/github-api-acceptance; touch /data/github-api-acceptance/storage-down.release' \
      >/dev/null 2>&1 || true
    if [ "$status" -ne 0 ]; then
      rm -f -- "$compose_log"
      compose logs app nginx > "$compose_log" 2>&1 || true
    fi
    compose exec -T app sh -ceu \
      'rm -f /data/github-api-acceptance/token /data/github-api-acceptance/storage-down.ready /data/github-api-acceptance/storage-down.release; rmdir /data/github-api-acceptance 2>/dev/null || true' \
      >/dev/null 2>&1 || true
    compose down --remove-orphans >/dev/null 2>&1 || true
    if owns_volume; then
      docker volume rm "$volume" >/dev/null 2>&1 || true
    fi
  fi
  if [ "$owns_artifacts" = true ]; then
    rm -f -- "$token_file" "$curl_config" "$health_down_file" "$compose_env"
  fi
  if [ "$owns_lock_container" = true ] &&
      [ "$(docker container inspect -f '{{ index .Config.Labels "fornacast.release-e2e.owner" }}' "$lock_container" 2>/dev/null || true)" = "$run_marker" ]; then
    docker rm -f "$lock_container" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

docker pull alpine:3.22 >/dev/null
if ! docker create --name "$lock_container" \
    --label "fornacast.release-e2e.owner=$run_marker" \
    alpine:3.22 true >/dev/null; then
  echo "refusing concurrent release acceptance: Docker lock $lock_container exists" >&2
  exit 1
fi
test "$(docker container inspect -f '{{ index .Config.Labels "fornacast.release-e2e.owner" }}' "$lock_container")" = "$run_marker"
owns_lock_container=true

ensure_safe_directory "$artifacts_root"
ensure_safe_directory "$acceptance_dir"
chmod 700 "$acceptance_dir"
reject_symlink "$backup_dir"
for path in "$token_file" "$state_file" "$curl_config" "$health_down_file" \
    "$compose_log" "$compose_env" "$listeners_before" "$listeners_after" \
    "$listeners_added" "$listeners_expected"; do
  prepare_output_file "$path"
done
owns_artifacts=true
printf '%s\n' '# isolated Compose interpolation; values come from the exact exports' > "$compose_env"
chmod 600 "$compose_env"

test "$volume" = "fornacast-release-e2e_fornacast-data"
test -z "$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")"
test -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")"
test -z "$(docker network ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")"
if docker volume inspect "$volume" >/dev/null 2>&1; then
  echo "refusing to reuse pre-existing acceptance volume: $volume" >&2
  exit 1
fi
docker volume create \
  --label "com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
  --label "com.docker.compose.volume=fornacast-data" \
  --label "fornacast.release-e2e.owner=$run_marker" \
  "$volume" >/dev/null
test "$(docker volume inspect -f '{{ index .Labels "fornacast.release-e2e.owner" }}' "$volume")" = "$run_marker"
owns_project=true

wait_for_storage_ready() {
  local user_agent="$1"

  for _attempt in $(seq 1 90); do
    if curl -fsS -H "User-Agent: $user_agent" "$health_url" |
        jq -e '.status == "ok" and .checks.release_asset_storage == "ok"' >/dev/null; then
      return 0
    fi
    sleep 2
  done

  return 1
}

ss -H -ltn | awk '{print $4}' | sed 's/.*://' | LC_ALL=C sort -u > "$listeners_before"

compose up --build -d app nginx

test "$(docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$volume")" = "$COMPOSE_PROJECT_NAME"
test "$(docker volume inspect -f '{{ index .Labels "com.docker.compose.volume" }}' "$volume")" = "fornacast-data"
test "$(docker volume inspect -f '{{ index .Labels "fornacast.release-e2e.owner" }}' "$volume")" = "$run_marker"
wait_for_storage_ready fornacast-release-e2e

printf '%s\n' "$run_marker" | compose exec -T app sh -ceu \
  "umask 077; cat > /data/$owner_marker; chmod 600 /data/$owner_marker"

ss -H -ltn | awk '{print $4}' | sed 's/.*://' | LC_ALL=C sort -u > "$listeners_after"
comm -13 "$listeners_before" "$listeners_after" > "$listeners_added"
printf '2222\n4000\n' | LC_ALL=C sort -u > "$listeners_expected"
diff -u "$listeners_expected" "$listeners_added"

compose exec -T app sh -ceu \
  'umask 077; mkdir -p /data/github-api-acceptance; chmod 700 /data/github-api-acceptance; rm -f /data/github-api-acceptance/token'
compose exec -T app /app/bin/fornacast rpc \
  "$(<scripts/github-api-acceptance/provision.exs); \
   FornacastAcceptance.Provision.run(\"/data/github-api-acceptance/token\")"
compose cp app:/data/github-api-acceptance/token "$token_file"
compose exec -T app sh -ceu \
  'rm -f /data/github-api-acceptance/token; test ! -e /data/github-api-acceptance/token'
chmod 600 "$token_file"

FORNACAST_PUBLIC_ORIGIN="$FORNACAST_BASE_URL" \
FORNACAST_ACCEPTANCE_TOKEN_FILE="$token_file" \
FORNACAST_ACCEPTANCE_STATE_FILE="$state_file" \
FORNACAST_ACCEPTANCE_SUFFIX="octokit-${GITHUB_RUN_ID:-local}" \
  node scripts/github-api-acceptance/octokit-workflow.mjs

FORNACAST_PUBLIC_ORIGIN="$FORNACAST_BASE_URL" \
FORNACAST_ACCEPTANCE_TOKEN_FILE="$token_file" \
FORNACAST_ACCEPTANCE_SUFFIX="gh-${GITHUB_RUN_ID:-local}" \
  bash scripts/github-api-acceptance/gh-workflow.sh

printf 'header = "Authorization: Bearer %s"\nheader = "User-Agent: fornacast-release-e2e"\n' \
  "$(<"$token_file")" > "$curl_config"
chmod 600 "$curl_config"

runtime_eval() {
  mode="$1"
  compose exec -T app /app/bin/fornacast rpc \
    "$(<scripts/github-api-acceptance/runtime-gate.exs); \
     FornacastAcceptance.RuntimeGate.run(\"$mode\")"
}

runtime_gc() {
  phase="$1"
  digest="$2"
  case "$phase" in candidate|delete) ;; *) return 2 ;; esac
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]]
  compose exec -T app /app/bin/fornacast rpc \
    "$(<scripts/github-api-acceptance/runtime-gate.exs); \
     FornacastAcceptance.RuntimeGate.run(\"gc\", \"$digest\", \"$phase\")"
}

runtime_hold_storage_not_ready() {
  compose exec -T app /app/bin/fornacast rpc \
    "$(<scripts/github-api-acceptance/runtime-gate.exs); \
     FornacastAcceptance.RuntimeGate.run(\"hold-storage-not-ready\", \
       \"$storage_down_ready\", \"$storage_down_release\")"
}

runtime_eval inspect
runtime_eval restart-storage

owner="$(jq -r .owner "$state_file")"
repo="$(jq -r .repo "$state_file")"
asset_id="$(jq -r .retainedAssetId "$state_file")"
asset_url="$FORNACAST_BASE_URL/api/v3/repos/$owner/$repo/releases/assets/$asset_id"
repo_url="$FORNACAST_BASE_URL/api/v3/repos/$owner/$repo"

compose exec -T app sh -ceu \
  'umask 077; mkdir -p /data/github-api-acceptance; chmod 700 /data/github-api-acceptance; rm -f /data/github-api-acceptance/storage-down.ready /data/github-api-acceptance/storage-down.release'
runtime_hold_storage_not_ready &
restart_pid=$!
for attempt in $(seq 1 240); do
  if compose exec -T app test -f "$storage_down_ready"; then
    break
  fi
  if ! kill -0 "$restart_pid" 2>/dev/null; then
    wait "$restart_pid"
    exit 1
  fi
  test "$attempt" != 240
  sleep 0.5
done

asset_status="$(curl -sS -o /dev/null -w '%{http_code}' --config "$curl_config" \
  -H 'Accept: application/octet-stream' "$asset_url")"
repo_status="$(curl -sS -o /dev/null -w '%{http_code}' --config "$curl_config" "$repo_url")"
health_status="$(curl -sS -o "$health_down_file" -w '%{http_code}' "$health_url")"
test "$asset_status" = 503
test "$repo_status" = 200
test "$health_status" = 503
jq -e '.status == "degraded" and .checks.release_asset_storage == "error"' \
  "$health_down_file" >/dev/null

compose exec -T app touch "$storage_down_release"
wait "$restart_pid"
compose exec -T app rm -f "$storage_down_ready" "$storage_down_release"
curl -fsS --config "$curl_config" -H 'Accept: application/octet-stream' "$asset_url" >/dev/null
curl -fsS "$health_url" | jq -e \
  '.status == "ok" and .checks.release_asset_storage == "ok"' >/dev/null

gc_digest="$(jq -r .gcDigest "$state_file")"
runtime_gc candidate "$gc_digest"

app_container="$(compose ps -q app)"
test -n "$app_container"
compose stop -t 45 app
test "$(docker inspect -f '{{.State.Running}}' "$app_container")" = false
test "$(docker inspect -f '{{.State.ExitCode}}' "$app_container")" = 0
test "$(docker inspect -f '{{.State.OOMKilled}}' "$app_container")" = false
compose start app
wait_for_storage_ready fornacast-release-e2e
curl -fsS --config "$curl_config" -H 'Accept: application/octet-stream' "$asset_url" >/dev/null
runtime_eval inspect
runtime_gc delete "$gc_digest"
runtime_eval inspect

FORNACAST_ACCEPTANCE_TOKEN_FILE="$token_file" \
FORNACAST_ACCEPTANCE_STATE_FILE="$state_file" \
FORNACAST_ACCEPTANCE_VOLUME_MARKER="$run_marker" \
  bash scripts/github-api-acceptance/docker-backup-restore-gate.sh
```

The token is supplied to curl through a mode-0600 config file, not a
command-line header. Before mutating any shared host artifact, the storage gate
atomically creates a fixed-name Docker lock container with a random ownership
label. It then rejects symlinked artifact directories and output leaves before
creating or truncating them. That
Docker-daemon-global name is shared across worktrees, so only one gate can
enter project preflight; a stale lock is a safe manual-cleanup failure, never
permission to delete. The gate refuses any container, volume, or network
already carrying the fixed Compose project label and separately refuses the
exact volume name. It pre-creates the volume with the Compose labels plus the
same random owner label and verifies that label before setting
`owns_project=true`, closing the check/create adoption race. It then writes the
same marker inside the volume. The cold-restore gate must match the owner
label, both Compose labels, and that marker before destructive volume work; it
verifies the owner label immediately after replacement volume creation and
before extraction. Both scripts set `umask 077` before creating credential
files. The storage gate invokes the cold-restore gate before returning, then
its `EXIT` trap removes the host token and curl config, best-effort removes the
container token, tears down only a still-owner-labeled project, and releases
only its owner-labeled Docker lock on every normal success or failure path.
Before project ownership is proven, the trap does not inspect, mutate, or stop
any Compose resource. The script must not print shell expansions, Docker
environment, or process listings.
Every Compose call uses one wrapper pinned to the physical checkout's exact
`docker-compose.yml`, fixed project name, and a mode-0600 explicit env file.
The checked-in file must be a non-symlink regular file.
It disables automatic `.env` loading and unsets caller-selected Compose files,
profiles, and env-file lists. All database adapters, local database/storage
paths, remote Turso URLs/tokens, and release-storage limits are overwritten
with the exact credential-free Turso `/data` gate values; Docker client context
variables remain available so explicitly selected local or CI daemons work.
`POSTGRES_PASSWORD` is a fixed non-secret placeholder used only because the
checked-in Compose model validates interpolation for the inactive PostgreSQL
profile; this Turso gate never starts that service.

Add `e2e-data` to `.dockerignore` and `/e2e-data/` to `.gitignore` before the
first image build. Recovery archives, client state, listener diagnostics, and
credential files must neither enter the Docker build context nor appear as
untracked source files.

- [ ] **Step 4: Implement the cold backup and restore gate**

Create `docker-backup-restore-gate.sh`. It backs up and replaces only the validated disposable volume owned by `COMPOSE_PROJECT_NAME=fornacast-release-e2e`:

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

: "${FORNACAST_ACCEPTANCE_TOKEN_FILE:?required}"
: "${FORNACAST_ACCEPTANCE_STATE_FILE:?required}"
: "${FORNACAST_ACCEPTANCE_VOLUME_MARKER:?required}"
: "${SECRET_KEY_BASE:?required}"
compose_file="$repo_root/docker-compose.yml"
if [ ! -f "$compose_file" ] || [ -L "$compose_file" ]; then
  echo "refusing non-regular Compose file: $compose_file" >&2
  exit 1
fi
export COMPOSE_PROJECT_NAME="fornacast-release-e2e"
export COMPOSE_DISABLE_ENV_FILE=1
export FORNACAST_IMAGE="fornacast-release-e2e:local"
export FORNACAST_DATABASE_ADAPTER="turso"
export FORNACAST_DATABASE_PATH="/data/fornacast.db"
export FORNACAST_CONFIG_DATABASE_PATH="/data/fornacast_config.db"
export TURSO_DATABASE_URL=""
export TURSO_AUTH_TOKEN=""
export FORNACAST_CONFIG_TURSO_DATABASE_URL=""
export FORNACAST_CONFIG_TURSO_AUTH_TOKEN=""
export CONCORD_TURSO_REMOTE_URL=""
export CONCORD_TURSO_AUTH_TOKEN=""
export DATABASE_URL=""
export FORNACAST_BASE_URL="http://127.0.0.1:4000"
export FORNACAST_REPO_STORAGE_ROOT="/data/repos"
export FORNACAST_RELEASE_ASSET_STORAGE_ROOT="/data/release-assets"
export FORNACAST_RELEASE_ASSET_MAX_BYTES="2147483648"
export FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS="86400"
export FORNACAST_SSH_HOST="localhost"
export FORNACAST_SSH_PORT="2222"
export POSTGRES_PASSWORD="fornacast-release-e2e-unused"
unset COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES
[[ "$FORNACAST_ACCEPTANCE_VOLUME_MARKER" =~ ^[0-9a-f]{32}$ ]]

acceptance_dir="$repo_root/e2e-data/release-api"
compose_env="$acceptance_dir/compose.env"
volume="${COMPOSE_PROJECT_NAME}_fornacast-data"
test "$volume" = "fornacast-release-e2e_fornacast-data"
owner_marker=".fornacast-release-e2e-owner"
lock_container="fornacast-release-e2e-lock"

compose() {
  docker compose --project-directory "$repo_root" --env-file "$compose_env" \
    -f "$compose_file" --project-name "$COMPOSE_PROJECT_NAME" "$@"
}

reject_symlink() {
  local path="$1"
  if [ -L "$path" ]; then
    echo "refusing symlinked acceptance path: $path" >&2
    exit 1
  fi
}

ensure_safe_directory() {
  local path="$1"
  reject_symlink "$path"
  if [ -e "$path" ]; then
    if [ ! -d "$path" ]; then
      echo "refusing non-directory acceptance path: $path" >&2
      exit 1
    fi
  else
    mkdir -- "$path"
  fi
  reject_symlink "$path"
  if [ ! -d "$path" ] || [ ! -O "$path" ]; then
    echo "refusing unowned acceptance directory: $path" >&2
    exit 1
  fi
}

prepare_output_file() {
  local path="$1"
  reject_symlink "$path"
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "refusing non-file acceptance output: $path" >&2
    exit 1
  fi
  rm -f -- "$path"
}

assert_owned_volume() {
  docker volume inspect "$volume" >/dev/null
  test "$(docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$volume")" = "$COMPOSE_PROJECT_NAME"
  test "$(docker volume inspect -f '{{ index .Labels "com.docker.compose.volume" }}' "$volume")" = "fornacast-data"
  test "$(docker volume inspect -f '{{ index .Labels "fornacast.release-e2e.owner" }}' "$volume")" = \
    "$FORNACAST_ACCEPTANCE_VOLUME_MARKER"
  test "$(docker run --rm -v "$volume:/source:ro" alpine:3.22 cat "/source/$owner_marker")" = \
    "$FORNACAST_ACCEPTANCE_VOLUME_MARKER"
}

test "$(docker container inspect -f '{{ index .Config.Labels "fornacast.release-e2e.owner" }}' "$lock_container")" = \
  "$FORNACAST_ACCEPTANCE_VOLUME_MARKER"
assert_owned_volume

test "$FORNACAST_ACCEPTANCE_TOKEN_FILE" = "$acceptance_dir/token"
test "$FORNACAST_ACCEPTANCE_STATE_FILE" = "$acceptance_dir/octokit-state.json"
for path in "$acceptance_dir" "$compose_env" "$FORNACAST_ACCEPTANCE_TOKEN_FILE" \
    "$FORNACAST_ACCEPTANCE_STATE_FILE"; do
  reject_symlink "$path"
done
test -d "$acceptance_dir"
test -O "$acceptance_dir"
for path in "$compose_env" "$FORNACAST_ACCEPTANCE_TOKEN_FILE" \
    "$FORNACAST_ACCEPTANCE_STATE_FILE"; do
  test -f "$path"
  test -O "$path"
done

backup_dir="$acceptance_dir/backup"
ensure_safe_directory "$backup_dir"
chmod 700 "$backup_dir"
curl_config="$backup_dir/curl.conf"
expected="$backup_dir/expected.bin"
actual="$backup_dir/restored.bin"
recovery_archive="$backup_dir/recovery-set.tgz"
recovery_list="$backup_dir/recovery-set.list"
for path in "$curl_config" "$expected" "$actual" "$recovery_archive" "$recovery_list"; do
  prepare_output_file "$path"
done
trap 'rm -f -- "$curl_config"' EXIT

owner="$(jq -r .owner "$FORNACAST_ACCEPTANCE_STATE_FILE")"
repo="$(jq -r .repo "$FORNACAST_ACCEPTANCE_STATE_FILE")"
asset_id="$(jq -r .retainedAssetId "$FORNACAST_ACCEPTANCE_STATE_FILE")"
printf '%s' "$(jq -r .retainedBytes "$FORNACAST_ACCEPTANCE_STATE_FILE")" | base64 -d > "$expected"

printf 'header = "Authorization: Bearer %s"\nheader = "User-Agent: fornacast-backup-e2e"\n' \
  "$(<"$FORNACAST_ACCEPTANCE_TOKEN_FILE")" > "$curl_config"
chmod 600 "$curl_config"

compose stop -t 45 app
app_container="$(compose ps -a -q app)"
test -n "$app_container"
test "$(docker inspect -f '{{.State.Running}}' "$app_container")" = false
test "$(docker inspect -f '{{.State.ExitCode}}' "$app_container")" = 0
test "$(docker inspect -f '{{.State.OOMKilled}}' "$app_container")" = false

docker run --rm \
  -v "$volume:/source:ro" \
  -v "$backup_dir:/backup" \
  alpine:3.22 sh -ceu 'tar -C /source -czf /backup/recovery-set.tgz .'

tar -tzf "$recovery_archive" > "$recovery_list"
grep -q '^\./fornacast.db' "$recovery_list"
grep -q '^\./fornacast_config.db' "$recovery_list"
grep -q '^\./release-assets/concord/' "$recovery_list"
grep -q '^\./release-assets/cas/' "$recovery_list"
grep -q '^\./release-assets/tmp/' "$recovery_list"
grep -q "^\./$owner_marker$" "$recovery_list"

compose rm -f app
assert_owned_volume
docker volume rm "$volume"
docker volume create \
  --label "com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
  --label "com.docker.compose.volume=fornacast-data" \
  --label "fornacast.release-e2e.owner=$FORNACAST_ACCEPTANCE_VOLUME_MARKER" \
  "$volume" >/dev/null
test "$(docker volume inspect -f '{{ index .Labels "fornacast.release-e2e.owner" }}' "$volume")" = \
  "$FORNACAST_ACCEPTANCE_VOLUME_MARKER"
docker run --rm \
  -v "$volume:/restore" \
  -v "$backup_dir:/backup:ro" \
  alpine:3.22 sh -ceu 'tar -C /restore -xzf /backup/recovery-set.tgz'
assert_owned_volume

compose up -d app
compose up -d --force-recreate --no-deps nginx
for _attempt in $(seq 1 90); do
  if curl -fsS -H 'User-Agent: fornacast-backup-e2e' \
      http://127.0.0.1:4000/health | \
      jq -e '.status == "ok" and .checks.release_asset_storage == "ok"' >/dev/null; then
    break
  fi
  sleep 2
done
curl -fsS -H 'User-Agent: fornacast-backup-e2e' \
  http://127.0.0.1:4000/health | \
  jq -e '.status == "ok" and .checks.release_asset_storage == "ok"' >/dev/null

curl -fsS --config "$curl_config" -H 'Accept: application/octet-stream' \
  "http://127.0.0.1:4000/api/v3/repos/$owner/$repo/releases/assets/$asset_id" > "$actual"
cmp "$expected" "$actual"

compose exec -T app /app/bin/fornacast rpc \
  "$(<scripts/github-api-acceptance/runtime-gate.exs); \
   FornacastAcceptance.RuntimeGate.run(\"inspect\")"
```

The archive covers the default Turso Ecto database, ConfigStore database,
Concord VSR metadata, CAS, staging roots, and acceptance ownership marker
because Plan 1 places the complete recovery set under `/data`. Restore occurs
only after a 45-second graceful stop reports exit code zero and the old app
container is removed. Both before deletion and after restoration, the fixed
volume must carry the expected Compose labels, random owner label, and exact
per-invocation marker. The empty replacement volume's owner label is checked
before archive extraction, so an idempotent `docker volume create` cannot
adopt foreign data. Its `EXIT` trap always deletes the backup curl config
containing the caller-owned token. The script must not generalize the volume
name or accept an arbitrary destructive target. It revalidates the fixed
Docker lock owner before creating backup outputs, rejects symlinked input and
output leaves, and reconstructs the same pinned, sanitized Compose wrapper.
After replacing the app container it force-recreates nginx, ensuring nginx
resolves the restored app before health and download verification.

- [ ] **Step 5: Document the exact operator backup boundary**

Add a `Release asset backup and restore` section to `README.md` containing this exact operational contract:

```text
The Ecto database, ConfigStore database, release-assets/concord,
release-assets/cas, and release-assets/tmp are one recovery set. Stop the
Fornacast BEAM and wait for bounded shutdown before copying any member. Restore
every member while the BEAM remains stopped, then start it. A PostgreSQL
deployment must take its PostgreSQL backup in the same stopped maintenance
window. The first release supports one BEAM, one exclusive asset volume, and
stop-before-start upgrades; it does not support rolling writers or a shared
multi-node asset root. The release-asset slice has no S3 port or credentials.
```

Include the Compose commands `docker compose stop -t 45 app`, an
operator-selected recoverable backup command for the named `fornacast-data`
volume, `docker compose start app`, and a restore warning that names all
members. The 45-second stop timeout is longer than the supervised ESS shutdown
bound; verify a clean zero exit before copying. Do not present the destructive
CI volume-replacement sequence as an operator command.

- [ ] **Step 6: Extend E2E with the production Docker gate**

Add a `release-api-storage` job to `.github/workflows/e2e.yml`. Keep the
existing native release smoke. The new job must build the checked-in Dockerfile
on Ubuntu 24.04 with the production BEAM/Rust versions and run through nginx on
`:4000`. The gate's ownership-aware `EXIT` trap is the only teardown path; the
workflow must not run an unconditional fixed-project cleanup after a preflight
refusal:

```yaml
  release-api-storage:
    name: Release API and LocalCAS Storage
    runs-on: ubuntu-24.04
    env:
      FORNACAST_DATABASE_ADAPTER: turso
      FORNACAST_BASE_URL: http://127.0.0.1:4000
      FORNACAST_SSH_PORT: "2222"
      POSTGRES_PASSWORD: fornacast-release-e2e-unused
      COMPOSE_PROJECT_NAME: fornacast-release-e2e
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "24"
          cache: npm
      - name: Install acceptance dependencies
        run: npm ci
      - name: Run public-origin storage, supervision, and cold-restore gate
        run: |
          SECRET_KEY_BASE="$(openssl rand -base64 48)" \
            bash scripts/github-api-acceptance/docker-storage-gate.sh
      - name: Upload diagnostics
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: release-api-storage-diagnostics
          path: |
            e2e-data/release-api/compose.log
            e2e-data/release-api/listeners.*
```

Do not upload the token, curl config, client state, backup archive, databases, CAS, or Concord metadata as artifacts. Configure Compose in Plan 1 so the app environment includes the release-asset root/GC settings and no S3 settings.

- [ ] **Step 7: Run the production gate locally**

Run:

```bash
mix test apps/fornacast_api/test/github_workflow_acceptance_test.exs --max-cases 1
npm ci
SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  bash scripts/github-api-acceptance/docker-storage-gate.sh
```

Expected: both clients complete through nginx; identical bytes share a digest;
deleting one asset leaves the other downloadable; terminal logical deletion
survives graceful stop/start and the deterministic GC pass reaches the
`absent` tombstone; eight ESS child deaths recover with different supervisor
PIDs, then an explicit published-readiness barrier holds asset and web-health
at `503` with the exact degraded check while repository reads stay `200`; both
health controllers report release-asset readiness after recovery; only SSH and
nginx are published on the host and no
ESS storage port listens in the container; all eight ESS workers and the S3 app
are absent; the retained asset downloads byte-for-byte after the cold
recovery-set restore; and no host/container token or curl config remains.

- [ ] **Step 8: Commit production acceptance and operator docs**

```bash
git add scripts/github-api-acceptance/runtime-gate.exs scripts/github-api-acceptance/docker-storage-gate.sh scripts/github-api-acceptance/docker-backup-restore-gate.sh apps/fornacast_api/test/github_workflow_acceptance_test.exs .github/workflows/e2e.yml .dockerignore .gitignore README.md
git commit -m "test(releases): prove LocalCAS production recovery"
```

### Task 5: Run both database adapters and the final release gate

**Files:**

- Verification only; no source changes are expected.

- [ ] **Step 1: Verify dependency and generated-contract integrity**

Run:

```bash
mix deps.get --check-locked
mix deps | rg '^\* ex_storage_service \(Hex package\) \(mix\)$'
test "$(rg -c '^  "ex_storage_service":' mix.lock)" -eq 1
rg -n '^  "ex_storage_service": \{:hex, :ex_storage_service, "0\.6\.2",' mix.lock
! rg 'ex_storage_service_s3' mix.lock
git diff --exit-code -- apps/fornacast_api/priv/openapi
```

Expected: the lock is complete, `ex_storage_service` resolves exactly to `0.6.2`, `ex_storage_service_s3` is absent from `mix.lock`, and regenerating/reading the pinned contract leaves no unstaged OpenAPI change. Do not upgrade ESS in this plan.

- [ ] **Step 2: Run the Turso release/API slice**

Use isolated database and storage paths so the command cannot touch developer data:

```bash
FORNACAST_TEST_DATABASE_PATH="$PWD/tmp/test/release-api-final.db" \
FORNACAST_TEST_CONFIG_DATABASE_PATH="$PWD/tmp/test/release-api-config-final.db" \
FORNACAST_RELEASE_ASSET_STORAGE_ROOT="$PWD/tmp/test/release-api-assets-final" \
mix test \
  apps/fornacast/test/operation_lease_test.exs \
  apps/forge_releases/test \
  apps/fornacast_api/test/release_controller_test.exs \
  apps/fornacast_api/test/release_asset_stream_test.exs \
  apps/fornacast_api/test/release_contract_test.exs \
  apps/fornacast_api/test/github_workflow_acceptance_test.exs \
  apps/fornacast_api/test/openapi_contract_test.exs \
  --max-cases 1
```

Expected: PASS with all lease, adapter, domain, stream, compatibility, script, and OpenAPI assertions.

- [ ] **Step 3: Run the same focused slice on PostgreSQL**

Start the repository's PostgreSQL 17 development service, then force a separate compile path because the adapter is selected at compile time:

```bash
FORNACAST_DATABASE_ADAPTER=postgres \
MIX_BUILD_PATH="$PWD/_build/release-api-postgres" \
POSTGRES_TEST_DB=fornacast_test \
FORNACAST_RELEASE_ASSET_STORAGE_ROOT="$PWD/tmp/test/release-api-assets-postgres" \
devenv shell -- mix test \
  apps/fornacast/test/operation_lease_test.exs \
  apps/forge_releases/test \
  apps/fornacast_api/test/release_controller_test.exs \
  apps/fornacast_api/test/release_asset_stream_test.exs \
  apps/fornacast_api/test/release_contract_test.exs \
  --max-cases 1
```

Expected: PASS through the checked-in devenv PostgreSQL 17 Unix socket, without
PostgreSQL-only row locks and with the same public behavior and lease/GC
fencing as Turso. Start the checked-in service first; its only initial database
is `fornacast_test`. Do not substitute a TCP host or a nonexistent database,
and do not alter application code to bypass this gate.

- [ ] **Step 4: Run the complete five-slice API and Git regression gate**

Run:

```bash
mix test \
  apps/fornacast/test/operation_lease_test.exs \
  apps/forge_accounts/test \
  apps/forge_repos/test \
  apps/git_core/test \
  apps/git_transport/test \
  apps/forge_issues/test \
  apps/forge_pulls/test \
  apps/forge_releases/test \
  apps/fornacast_api/test \
  apps/fornacast_web/test/git_http_auth_test.exs \
  apps/fornacast_web/test/git_http_push_test.exs \
  apps/fornacast_web/test/fornacast_run_task_test.exs \
  --max-cases 1
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml
```

Expected: PASS for all five delivery slices, normal Git interoperability, and the Rust NIF. If an out-of-scope test fails, record it and stop; do not repair unrelated code under this plan.

- [ ] **Step 5: Build and inspect the production release**

Run with the exact production toolchain selected by CI:

```bash
mix format --check-formatted
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix release fornacast --overwrite
SECRET_KEY_BASE="$(openssl rand -base64 48)" \
FORNACAST_BASE_URL=http://127.0.0.1:4890 \
FORNACAST_DATABASE_PATH="$PWD/tmp/release-inspection.db" \
FORNACAST_CONFIG_DATABASE_PATH="$PWD/tmp/release-inspection-config.db" \
FORNACAST_REPO_STORAGE_ROOT="$PWD/tmp/release-inspection-repos" \
FORNACAST_SSH_HOST=127.0.0.1 \
FORNACAST_SSH_PORT=2222 \
FORNACAST_SSH_SYSTEM_DIR="$PWD/tmp/release-inspection-ssh" \
FORNACAST_RELEASE_ASSET_STORAGE_ROOT="$PWD/tmp/release-inspection-assets" \
MIX_ENV=prod _build/prod/rel/fornacast/bin/fornacast eval '
  true = Application.spec(:ex_storage_service) != nil
  nil = Application.spec(:ex_storage_service_s3)
  :non_existing = :code.which(ExStorageServiceS3.Application)
  true = Enum.member?(Application.spec(:fornacast, :applications), :concord)
  IO.puts("release-inspection-ok")
'
```

Expected: formatting, warnings-as-errors compilation, and release construction pass; output contains `release-inspection-ok`; the ESS core and Concord are present, while the S3 application/module are absent.

- [ ] **Step 6: Re-run the Docker public-origin and recovery-set gates**

Run from a clean Compose project:

```bash
npm ci
SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  bash scripts/github-api-acceptance/docker-storage-gate.sh
```

Expected: the complete nginx/client/health/GC/graceful-restart/worker/listener/backup/restore assertions pass again on the final release inputs, and trap cleanup leaves no raw token or curl config behind.

- [ ] **Step 7: Inspect the final diff and commit state**

Run:

```bash
git diff --check
git status --short
git log --oneline -5
```

Expected: no whitespace errors; only intentional plan-execution changes are present; the implementation is split into the four scoped commits from Tasks 1 through 4. Do not create a catch-all cleanup commit.

## Completion criteria

- Every release and asset operation in delivery slice `5` validates against both pinned API versions, and the generated marker is exactly `5`.
- Release/tag semantics, draft/private visibility, pagination, scopes, errors, canonical URLs, and null source archives retain the approved contract.
- Upload authorization, declared-length admission, quota, and name reservation complete before the first request byte is read.
- The API passes one credential-free opaque reader state to `stream_asset_upload/3`; it never drives chunk/finish calls and never aborts after streaming begins.
- Upload and download remain bounded and streaming, return the latest connection/handle state, and never expose a path or ESS value.
- Octokit, `gh api`, and normal Git complete the organization-to-release workflow through nginx's public origin.
- Identical assets deduplicate; deleting one cannot damage another; user-visible deletion is immediate; delayed GC reaches an `absent` tombstone after graceful stop/start.
- Eight ESS child deaths recover with different supervisor PIDs and bounded backoff; a separate deterministic readiness barrier proves release assets and health return `503` while unrelated repository reads remain available, then releases and recovers.
- Runtime inspection proves all eight ESS workers are disabled, the S3 app/module is absent, and no storage listener is bound.
- Runtime inspection proves the fixed path-free capacity, nonterminal-operation, and six-state blob telemetry snapshot is callable and normalized.
- A stopped-BEAM backup and complete restore of Ecto, ConfigStore, Concord metadata, CAS, and staging roots preserves a retained downloadable asset.
- Turso, PostgreSQL, production compilation, OTP release construction, Docker graceful stop/start, and the five-slice regression gate all pass with fresh evidence.
