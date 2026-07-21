# GitHub-Compatible API Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the first reviewable GitHub-compatible REST slice: a separately supervised API listener with pinned dual-version contracts, classic PAT authentication, common protocol behavior, users, organizations, repositories, and PAT-only Git smart-HTTP authentication.

**Architecture:** Add `fornacast_api` as an HTTP-only umbrella application whose controllers translate the pinned GHES contract into tagged operations owned by `forge_accounts` and `forge_repos`. Keep request policy in focused plugs, persistence and authorization in domain contexts, and wire output in explicit versioned serializers; the API app never depends on `fornacast_web`, and neither domain app depends on an HTTP app. This plan establishes the stable extension points used by the Git-data, issue, pull-request, and release plans without implementing those resource families here.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, Bandit 1.12, Plug 1.20, Ecto 3.14 with Turso and PostgreSQL, Elixir `JSON`, OpenApiSpex 3.22 for test-only contract validation, ExUnit, Phoenix.ConnTest, Nginx reverse-proxy configuration, and the pinned GHES 3.21 OpenAPI descriptions.

---

**Approved specification:** `docs/superpowers/specs/2026-07-21-github-compatible-api-design.md`

## Scope and execution guardrails

- This plan covers the approved specification from Application Architecture through Repositories, the shared verification required by those sections, and the explicit Git HTTP password-removal migration.
- The checked-in OpenAPI artifacts pin the complete approved first-release operation manifest from the start. Their `x-fornacast-implemented-through-slice` marker is `1`; unimplemented later-slice routes still hit the API catch-all until their controller plan lands. Later plans advance only that generated delivery marker plus their codecs, fixtures, and routes, never redefine the compatibility boundary.
- Do not add branch, commit, contents, issue, pull-request, release, asset, tag-write, merge, or durable Git-write implementation in this slice.
- Keep controllers as protocol adapters. They may select a validator, call one domain operation, and select a serializer. They may not contain Ecto queries, role rules, token-scope rules, Git traversal, filesystem access, or recovery state machines.
- Authorize a repository before calling `ForgeRepos.absolute_storage_path/1`, `GitCore`, or a filesystem function. Mask inaccessible private resources as `404`.
- `fornacast_api` may depend on `fornacast`, `forge_accounts`, `forge_repos`, and `git_core`. It must not depend on `fornacast_web`, `git_transport`, or domain applications introduced by later plans.
- `forge_accounts` continues to depend only on `fornacast`. `forge_repos` continues to depend on `fornacast`, `forge_accounts`, and `git_core`. Do not reverse either dependency.
- The accepted repository-create contract includes `auto_init`. In this slice, `false` creates an empty bare repository and `true` returns the tagged temporary dependency result `{:error, :git_initializer_unavailable}`, rendered as sanitized `503`. Plan 2 replaces that branch with real blob, tree, commit, and compare-and-swap ref creation. Do not invoke the `git` executable, manufacture a commit through receive-pack, silently ignore `auto_init`, or claim first-release API compatibility before plan 2 passes the auto-initialize contract.
- API-created repositories default to public when both `private` and `visibility` are absent. The existing browser flow retains its private default because it continues to call `ForgeRepos.create_repository/2`.
- New PAT creation accepts only `repo`, `public_repo`, `read:org`, and `write:org`. Existing stored `repo:read` and `repo:write` values remain authentication inputs for the migration rules; no migration rewrites them.
- Every test in this slice runs serially when it touches Turso or global application configuration. Use `--max-cases 1` in combined commands.
- Format only touched Elixir files. If an out-of-scope test fails, record the failure and stop rather than widening this slice.
- Any dependency defect in an organization named by the repository's upstream-dependency policy must be routed through that policy before a local workaround is considered.

## Fixed public contracts

### Listener and URL contract

| Concern | Contract |
| --- | --- |
| Browser and Git listener | `fornacast_web`, development port `4890` |
| REST and upload listener | `fornacast_api`, development and test port `4001` |
| Versioned REST root | `/api/v3` |
| Release-upload root reserved for plan 5 | `/api/uploads` |
| Operational health | `/health`, exempt from API policy and GitHub headers |
| Public links | Built from `Fornacast.Config.base_url/0`, never from the API listener or request `Host` |
| Production API bind | `FORNACAST_API_BIND_IP`, default `127.0.0.1` |
| Production API port | `FORNACAST_API_PORT`, required in a release command |
| Trusted proxies | `FORNACAST_API_TRUSTED_PROXIES`, comma-separated IPv4 or IPv6 CIDRs, default empty |

### Plan-1 route manifest

| Method | Path | Authentication and permission |
| --- | --- | --- |
| `GET` | `/health` | Exempt |
| `GET` | `/api/v3/versions` | Anonymous; consumes the normal core quota |
| `GET` | `/api/v3/rate_limit` | Anonymous or PAT; no quota consumption |
| `GET` | `/api/v3/user` | Any valid classic or legacy PAT |
| `GET` | `/api/v3/users/:username` | Anonymous for an active user |
| `GET` | `/api/v3/user/orgs` | `read:org` or `write:org` |
| `GET` | `/api/v3/orgs/:org` | Anonymous for an active organization |
| `PATCH` | `/api/v3/orgs/:org` | Organization owner or site administrator plus `write:org` |
| `POST` | `/api/v3/admin/organizations` | Ordinary caller naming self, or site administrator naming an active user, plus `write:org` |
| `GET` | `/api/v3/user/repos` | Valid PAT; private reads require `repo` or legacy repository scope, while `public_repo` lists public repositories only |
| `POST` | `/api/v3/user/repos` | Owner plus `repo` for private or `public_repo` or `repo` for public |
| `GET` | `/api/v3/users/:username/repos` | Anonymous public rows plus private rows readable by the authenticated caller |
| `GET` | `/api/v3/orgs/:org/repos` | Anonymous public rows plus private rows readable by the authenticated caller |
| `POST` | `/api/v3/orgs/:org/repos` | Organization owner or site administrator plus repository mutation scope |
| `GET` | `/api/v3/repos/:owner/:repo` | Anonymous public read or authorized private read |
| `PATCH` | `/api/v3/repos/:owner/:repo` | Repository writer or administrator plus repository mutation scope |

All other method/path pairs below `/api/v3` and `/api/uploads` return the common `404` body. This catch-all is not an implemented resource operation.

### Version, media, pagination, and rate contracts

```elixir
@supported_versions ["2022-11-28", "2026-03-10"]
@default_version "2022-11-28"
@json_media_types ["application/vnd.github+json", "application/json"]
@github_media_type "github.v3; format=json"
@anonymous_limit 60
@authenticated_limit 5_000
@window_seconds 3_600
@default_page 1
@default_per_page 30
@maximum_per_page 100
@ordinary_json_limit 1_048_576
@request_target_limit 8_192
@ordinary_body_total_timeout_ms 15_000
```

- A non-empty `User-Agent` is required below `/api/v3` and `/api/uploads`.
- Missing `X-GitHub-Api-Version` selects `2022-11-28`; any other unsupported value returns `400 Bad Request`.
- JSON endpoints accept no `Accept` header, `application/vnd.github+json`, or `application/json`. Commit and pull diff/patch media are reserved for plan 4 and remain `406`.
- JSON mutation bodies require `application/vnd.github+json` or `application/json`, reject duplicate object keys, and stop at `1 MiB` in this slice.
- Collections accept positive integer `page` and `per_page`; `per_page` is at most `100`. Invalid values return `422` rather than being silently normalized.
- `GET /api/v3/rate_limit` reports a bucket but does not consume it. Every other API request, including `GET /api/v3/versions` and errors, consumes one request.
- Anonymous buckets are keyed by normalized effective client IP. Authenticated buckets are keyed by API-key database ID. Raw PATs are never keys, logs, telemetry values, or audit metadata.

### Classic and legacy scope contract

```elixir
@classic_scopes ["repo", "public_repo", "read:org", "write:org"]
@legacy_scopes ["repo:read", "repo:write"]

@scope_inheritance %{
  "repo" => ["repo", "public_repo"],
  "public_repo" => ["public_repo"],
  "write:org" => ["write:org", "read:org"],
  "read:org" => ["read:org"],
  "repo:write" => ["repo:write", "repo:read"],
  "repo:read" => ["repo:read"]
}
```

| Operation class | Accepted stored scopes |
| --- | --- |
| `GET /user` | Any non-empty classic or legacy scope set |
| Organization membership read | `read:org`, `write:org` |
| Organization mutation | `write:org` |
| Public repository read with PAT | `repo`, `public_repo`, `repo:read`, `repo:write` |
| Private repository read | `repo`, `repo:read`, `repo:write` |
| Public repository mutation | `repo`, `public_repo` |
| Private repository mutation | `repo` |
| Public Git Basic read | `repo`, `public_repo`, `repo:read`, `repo:write` |
| Private Git Basic read | `repo`, `repo:read`, `repo:write` |
| Public Git Basic write | `repo`, `public_repo`, `repo:write` |
| Private Git Basic write | `repo`, `repo:write` |

`read:org` and `write:org` alone never authorize Git transport. `repo:write` is not treated as classic `repo` for REST mutations.

### Domain result contract

The API boundary consumes tagged domain results only:

```elixir
@type validation_error :: %{
        required(:resource) => String.t(),
        required(:field) => String.t(),
        required(:code) =>
          :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
        optional(:message) => String.t()
      }

@type domain_error ::
        :invalid_credentials
        | :insufficient_scope
        | :forbidden
        | :not_found
        | :git_initializer_unavailable
        | {:conflict, String.t()}
        | {:validation, [validation_error()]}
        | {:unavailable, atom()}

@type domain_result(value) :: {:ok, value} | {:error, domain_error()}
```

Ecto changesets, native Git errors, storage paths, and raw database exceptions do not cross this boundary.

## File map

### Pinned contract and generated fixtures

- Modify `mix.lock`: lock the test-only OpenAPI dependency added by the API application.
- Create `scripts/prune_github_openapi.exs`: deterministically select the approved method/path pairs from the two pinned dereferenced GHES documents and apply the Fornacast overlay.
- Create `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`: checked-in pruned contract generated from pinned blob `bb38aa30e1d0a15a847180794970f25ef2454b8c`.
- Create `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`: checked-in pruned contract generated from pinned blob `02e93bd95f712c171b23c6a869ac9c0d88d89640`.
- Create `apps/fornacast_api/priv/openapi/fornacast-overlay.json`: operation ownership, local `/versions`, upload server override, deliberate divergences, and delivery-slice metadata.
- Create `apps/fornacast_api/test/openapi_contract_test.exs`: provenance, operation-manifest, schema, and golden-response validation.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/foundation.json`: deterministic plan-1 success and error responses.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/foundation.json`: deterministic plan-1 success and error responses with 2026 schema differences.

### API application and common protocol boundary

- Create `apps/fornacast_api/mix.exs`: one-way umbrella and Phoenix/Bandit dependencies.
- Create `apps/fornacast_api/lib/fornacast_api.ex`: local controller and router macros.
- Create `apps/fornacast_api/lib/fornacast_api/application.ex`: API endpoint and rate-counter supervision.
- Create `apps/fornacast_api/lib/fornacast_api/endpoint.ex`: request ID, telemetry, target bound, and router only.
- Create `apps/fornacast_api/lib/fornacast_api/router.ex`: health, `/api/v3`, reserved `/api/uploads`, and catch-all routes.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/health_controller.ex`: operational health without API policy.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/meta_controller.ex`: versions and rate-limit resources.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/fallback_controller.ex`: sanitized API catch-all handling.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/error_json.ex`: JSON fallback rendering.
- Create `apps/fornacast_api/lib/fornacast_api/error.ex`: sanitized error struct and deterministic domain mapping.
- Create `apps/fornacast_api/lib/fornacast_api/response.ex`: JSON response and common header finalization.
- Create `apps/fornacast_api/lib/fornacast_api/json.ex`: duplicate-key-safe JSON decoding.
- Create `apps/fornacast_api/lib/fornacast_api/request_validator.ex`: shared type, required-field, unknown-field, and field-conflict engine.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`: explicit plan-1 2022 mutation schemas.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`: explicit plan-1 2026 mutation schemas.
- Create `apps/fornacast_api/lib/fornacast_api/plugs/request_context.ex`: API-path detection, selected defaults, request ID, and before-send response headers.
- Create `apps/fornacast_api/lib/fornacast_api/plugs/request_target.ex`: `8 KiB` request-target enforcement before parsing.
- Create `apps/fornacast_api/lib/fornacast_api/plugs/user_agent.ex`: non-empty `User-Agent` enforcement.
- Create `apps/fornacast_api/lib/fornacast_api/plugs/api_version.ex`: dual-version selection.
- Create `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex`: response and request media negotiation.
- Create `apps/fornacast_api/lib/fornacast_api/request_body.ex`: target-authorized, bounded incremental read and duplicate-key-safe decode.
- Create `apps/fornacast_api/lib/fornacast_api/plugs/authentication.ex`: optional Bearer/token PAT parsing with invalid-token retention.
- Create `apps/fornacast_api/lib/fornacast_api/authentication.ex`: redacted authenticated-request value.
- Create `apps/fornacast_api/lib/fornacast_api/plugs/rate_limit.ex`: exactly-once bucket consumption or peek.
- Create `apps/fornacast_api/lib/fornacast_api/client_ip.ex`: trusted-proxy and normalized client-IP logic.
- Create `apps/fornacast_api/lib/fornacast_api/rate_limit.ex`: supervised ETS-backed fixed-window counters.
- Create `apps/fornacast_api/lib/fornacast_api/pagination.ex`: validated pagination and RFC 8288 links.
- Create `apps/fornacast_api/lib/fornacast_api/url.ex`: public API, upload, and web URL construction from `Fornacast.Config.base_url/0`.
- Create `apps/fornacast_api/lib/fornacast_api/serializer.ex`: selected-version serializer facade.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`: 2022 user, organization, repository, rate, and error maps.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`: 2026 maps with version-specific omissions.

### Accounts, repositories, and controllers

- Modify `apps/forge_accounts/lib/forge_accounts/api_key.ex`: classic creation scopes and stored-scope helpers.
- Create `apps/forge_accounts/lib/forge_accounts/api_scope.ex`: classic inheritance plus explicit legacy migration mappings.
- Modify `apps/forge_accounts/lib/forge_accounts/organization.ex`: profile update changeset.
- Modify `apps/forge_accounts/lib/forge_accounts.ex`: token-only auth, organization authorization/create/update, paginated profile reads, and tagged errors.
- Modify `apps/forge_accounts/test/api_key_test.exs`: classic creation, token-only lookup, hierarchy, and legacy stored-key cases.
- Modify `apps/forge_accounts/test/forge_accounts_test.exs`: organization API-domain operations and pagination.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/api_key_controller.ex`: classic scope checkboxes only.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`: PAT-only Basic authentication and visibility-aware scope checks.
- Modify `apps/fornacast_web/test/fornacast_web_test.exs`: classic settings flow.
- Modify `apps/fornacast_web/test/git_http_auth_test.exs`: reject account passwords and cover classic/legacy mapping.
- Create `apps/fornacast/priv/repo/migrations/20260721000100_add_api_repository_settings.exs`: repository feature booleans.
- Modify `apps/forge_repos/lib/forge_repos/repository.ex`: new fields and separate API create/update changesets.
- Create `apps/forge_repos/lib/forge_repos/repository_view.ex`: domain-owned owner, permission, and bounded metadata view.
- Modify `apps/forge_repos/lib/forge_repos.ex`: collaborator-complete listings, pagination, API create/update operations, rename/default-branch rules, and the plan-2 initializer handoff.
- Modify `apps/forge_repos/test/access_test.exs`: preserve the permission matrix.
- Modify `apps/forge_repos/test/forge_repos_test.exs`: API repository operations, collaborator listing, fields, rename, and initializer handoff.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/user_controller.ex`: `/user` and `/users/:username` adapters.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/organization_controller.ex`: organization list/get/create/update adapters.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/repository_controller.ex`: repository list/get/create/update adapters.
- Create `apps/fornacast_api/test/support/conn_case.ex`: endpoint case with serial database isolation.
- Create `apps/fornacast_api/test/support/fixtures.ex`: users, PATs, organizations, collaborators, and repositories.
- Create `apps/fornacast_api/test/test_helper.exs`: support loading and PostgreSQL sandbox mode.
- Create `apps/fornacast_api/test/endpoint_test.exs`: independent listener and health tests.
- Create `apps/fornacast_api/test/request_pipeline_test.exs`: protocol and error cases.
- Create `apps/fornacast_api/test/rate_limit_test.exs`: quota and proxy cases.
- Create `apps/fornacast_api/test/authentication_test.exs`: REST PAT cases and scope headers.
- Create `apps/fornacast_api/test/users_organizations_test.exs`: account endpoints.
- Create `apps/fornacast_api/test/repositories_test.exs`: repository endpoints and masking.
- Create `apps/fornacast_api/test/serialization_test.exs`: explicit dual-version serializer contract.
- Create `apps/fornacast/lib/fornacast/page.ex`: shared deterministic page value.
- Modify `apps/fornacast/lib/fornacast/audit.ex`: composable transactional audit insertion.
- Modify `apps/fornacast/test/fornacast_test.exs`: pagination and audit composition tests.
- Modify `apps/forge_accounts/lib/forge_accounts/user.ex`: public context type and profile fields.

### Release, development, and deployment wiring

- Modify `mix.exs`: add `fornacast_api` to the release application list.
- Modify `config/config.exs`: base API endpoint, policy limits, and trusted-proxy defaults.
- Modify `config/dev.exs`: independently running API listener on port `4001`.
- Modify `config/test.exs`: API endpoint with `server: false` and isolated policy configuration.
- Modify `config/prod.exs`: enable the API endpoint.
- Modify `config/runtime.exs`: explicit production bind, port, and proxy CIDRs.
- Modify `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`: start `fornacast_api` before `phx.server` starts web.
- Modify `apps/fornacast_web/test/fornacast_run_task_test.exs`: assert both endpoints without adding a web-to-API dependency.
- Create `deploy/nginx/fornacast.conf`: preserve `/api/v3` and `/api/uploads` while proxying them to the API listener.
- Modify `Dockerfile`: expose and configure separate internal web/API ports.
- Modify `docker-compose.yml`: make Nginx the public HTTP listener and keep SSH direct.
- Modify `README.md`: document the two listeners, same-origin proxy, classic PATs, and the incomplete `auto_init` release gate.
- Create `apps/fornacast_api/test/proxy_contract_test.exs`: static proxy path-preservation contract.
- Create `scripts/api_proxy_smoke.sh`: live same-origin health, REST, and upload-prefix smoke.

### Task 1: Check in the pinned dual-version OpenAPI contract

**Files:**
- Modify: `mix.lock`
- Create: `apps/fornacast_api/mix.exs`
- Create: `apps/fornacast_api/test/test_helper.exs`
- Create: `scripts/prune_github_openapi.exs`
- Create: `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`
- Create: `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`
- Create: `apps/fornacast_api/priv/openapi/fornacast-overlay.json`
- Create: `apps/fornacast_api/test/openapi_contract_test.exs`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/foundation.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/foundation.json`

- [ ] **Step 1: Add the final Mix boundary and write the failing provenance test**

Create `apps/fornacast_api/mix.exs` with the final dependency boundary shown in Task 2, including `open_api_spex` as a test-only non-runtime dependency, and create `apps/fornacast_api/test/test_helper.exs` containing `ExUnit.start()`. The application callback may name `FornacastAPI.Application` before Task 2 because these contract-only test commands use `--no-start`. Add `openapi_contract_test.exs` with these exact assertions:

```elixir
defmodule FornacastAPI.OpenAPIContractTest do
  use ExUnit.Case, async: true

  @contract_root Path.expand("../priv/openapi", __DIR__)
  @source_commit "03ca9c1cac754ec9b8369dc75de8a8c753c6e087"
  @contracts %{
    "2022-11-28" => {
      "ghes-3.21-2022-11-28.json",
      "bb38aa30e1d0a15a847180794970f25ef2454b8c"
    },
    "2026-03-10" => {
      "ghes-3.21-2026-03-10.json",
      "02e93bd95f712c171b23c6a869ac9c0d88d89640"
    }
  }

  @foundation_operations MapSet.new([
    {"get", "/versions"},
    {"get", "/rate_limit"},
    {"get", "/user"},
    {"get", "/users/{username}"},
    {"get", "/user/orgs"},
    {"get", "/orgs/{org}"},
    {"patch", "/orgs/{org}"},
    {"post", "/admin/organizations"},
    {"get", "/user/repos"},
    {"post", "/user/repos"},
    {"get", "/users/{username}/repos"},
    {"get", "/orgs/{org}/repos"},
    {"post", "/orgs/{org}/repos"},
    {"get", "/repos/{owner}/{repo}"},
    {"patch", "/repos/{owner}/{repo}"}
  ])

  test "contracts retain pinned provenance and the foundation operations" do
    for {version, {filename, source_blob}} <- @contracts do
      document = filename |> contract_path() |> File.read!() |> JSON.decode!()

      assert document["openapi"] =~ ~r/^3\.0\./
      assert document["x-fornacast-source-commit"] == @source_commit
      assert document["x-fornacast-source-blob"] == source_blob
      assert document["x-github-api-version"] == version
      assert document["x-fornacast-implemented-through-slice"] == "1"
      assert MapSet.subset?(@foundation_operations, operations(document))
      assert get_in(document, ["paths", "/repos/{owner}/{repo}", "get"])
    end
  end

  test "overlay owns every operation and reserves the upload server" do
    overlay = "fornacast-overlay.json" |> contract_path() |> File.read!() |> JSON.decode!()

    assert overlay["source_commit"] == @source_commit
    assert overlay["versions"] == ["2022-11-28", "2026-03-10"]
    assert overlay["servers"]["rest"] == "/api/v3"
    assert overlay["servers"]["uploads"] == "/api/uploads"
    assert overlay["implemented_through_slice"] == "1"
    expected_foundation =
      @foundation_operations
      |> MapSet.to_list()
      |> Enum.map(fn {method, path} -> [method, path] end)
      |> Enum.sort()

    assert overlay["delivery_slices"]["1"] == expected_foundation
    assert Enum.sort(Map.keys(overlay["delivery_slices"])) == ~w(1 2 3 4 5)
  end

  defp contract_path(filename), do: Path.join(@contract_root, filename)

  defp operations(document) do
    document["paths"]
    |> Enum.flat_map(fn {path, item} ->
      for method <- ~w(get post put patch delete), Map.has_key?(item, method), do: {method, path}
    end)
    |> MapSet.new()
  end
end
```

- [ ] **Step 2: Run the contract test and verify the files are missing**

Run:

```bash
mix deps.get
mix test --no-start apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

Expected: FAIL because `fornacast_api` or the three OpenAPI documents do not exist. The failure must name one of the exact paths above.

- [ ] **Step 3: Add the deterministic pruning script and overlay manifest**

The script must pin these two inputs and reject a different Git blob SHA before parsing:

```elixir
defmodule Fornacast.OpenAPIPruner do
  @source_commit "03ca9c1cac754ec9b8369dc75de8a8c753c6e087"
  @sources %{
    "2022-11-28" => %{
      blob: "bb38aa30e1d0a15a847180794970f25ef2454b8c",
      path: "descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json"
    },
    "2026-03-10" => %{
      blob: "02e93bd95f712c171b23c6a869ac9c0d88d89640",
      path: "descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json"
    }
  }

  @delivery_slices %{
    "1" => [
      {"get", "/versions"},
      {"get", "/rate_limit"},
      {"get", "/user"},
      {"get", "/users/{username}"},
      {"get", "/user/orgs"},
      {"get", "/orgs/{org}"},
      {"patch", "/orgs/{org}"},
      {"post", "/admin/organizations"},
      {"get", "/user/repos"},
      {"post", "/user/repos"},
      {"get", "/users/{username}/repos"},
      {"get", "/orgs/{org}/repos"},
      {"post", "/orgs/{org}/repos"},
      {"get", "/repos/{owner}/{repo}"},
      {"patch", "/repos/{owner}/{repo}"}
    ],
    "2" => [
      {"get", "/repos/{owner}/{repo}/branches"},
      {"get", "/repos/{owner}/{repo}/branches/{branch}"},
      {"get", "/repos/{owner}/{repo}/git/ref/{ref}"},
      {"post", "/repos/{owner}/{repo}/git/refs"},
      {"patch", "/repos/{owner}/{repo}/git/refs/{ref}"},
      {"get", "/repos/{owner}/{repo}/commits"},
      {"get", "/repos/{owner}/{repo}/commits/{ref}"},
      {"get", "/repos/{owner}/{repo}/contents/{path}"},
      {"put", "/repos/{owner}/{repo}/contents/{path}"},
      {"delete", "/repos/{owner}/{repo}/contents/{path}"}
    ],
    "3" => [
      {"get", "/repos/{owner}/{repo}/issues"},
      {"post", "/repos/{owner}/{repo}/issues"},
      {"get", "/repos/{owner}/{repo}/issues/{issue_number}"},
      {"patch", "/repos/{owner}/{repo}/issues/{issue_number}"},
      {"get", "/repos/{owner}/{repo}/issues/{issue_number}/comments"},
      {"post", "/repos/{owner}/{repo}/issues/{issue_number}/comments"},
      {"patch", "/repos/{owner}/{repo}/issues/comments/{comment_id}"},
      {"delete", "/repos/{owner}/{repo}/issues/comments/{comment_id}"}
    ],
    "4" => [
      {"get", "/repos/{owner}/{repo}/pulls"},
      {"post", "/repos/{owner}/{repo}/pulls"},
      {"get", "/repos/{owner}/{repo}/pulls/{pull_number}"},
      {"patch", "/repos/{owner}/{repo}/pulls/{pull_number}"},
      {"get", "/repos/{owner}/{repo}/pulls/{pull_number}/merge"},
      {"put", "/repos/{owner}/{repo}/pulls/{pull_number}/merge"}
    ],
    "5" => [
      {"get", "/repos/{owner}/{repo}/releases"},
      {"post", "/repos/{owner}/{repo}/releases"},
      {"get", "/repos/{owner}/{repo}/releases/latest"},
      {"get", "/repos/{owner}/{repo}/releases/tags/{tag}"},
      {"get", "/repos/{owner}/{repo}/releases/{release_id}"},
      {"patch", "/repos/{owner}/{repo}/releases/{release_id}"},
      {"delete", "/repos/{owner}/{repo}/releases/{release_id}"},
      {"get", "/repos/{owner}/{repo}/releases/{release_id}/assets"},
      {"post", "/repos/{owner}/{repo}/releases/{release_id}/assets"},
      {"get", "/repos/{owner}/{repo}/releases/assets/{asset_id}"},
      {"patch", "/repos/{owner}/{repo}/releases/assets/{asset_id}"},
      {"delete", "/repos/{owner}/{repo}/releases/assets/{asset_id}"}
    ]
  }

  def run([source_root, output_root, implemented_through])
      when implemented_through in ~w(1 2 3 4 5) do
    File.mkdir_p!(output_root)

    Enum.each(@sources, fn {version, source} ->
      source_file = Path.join(source_root, source.path)
      verify_blob!(source_file, source.blob)
      document = source_file |> File.read!() |> JSON.decode!()
      pruned = prune(document, version, source.blob, implemented_through)

      output = Path.join(output_root, "ghes-3.21-#{version}.json")
      File.write!(output, JSON.encode!(pruned))
    end)

    File.write!(
      Path.join(output_root, "fornacast-overlay.json"),
      JSON.encode!(overlay(implemented_through))
    )
  end

  def run(_args) do
    raise "usage: mix run scripts/prune_github_openapi.exs -- SOURCE_ROOT OUTPUT_ROOT IMPLEMENTED_THROUGH_SLICE"
  end

  defp verify_blob!(path, expected) do
    {actual, 0} = System.cmd("git", ["hash-object", path])
    actual = String.trim(actual)

    if actual != expected do
      raise "OpenAPI source blob mismatch for #{path}: expected #{expected}, got #{actual}"
    end
  end

  defp prune(document, version, source_blob, implemented_through) do
    operations = @delivery_slices |> Map.values() |> List.flatten()

    paths =
      operations
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Map.new(fn {path, methods} ->
        path_item = Map.fetch!(document["paths"], path)
        preserved = Map.take(path_item, ["parameters", "servers", "summary", "description"])
        {path, Map.merge(preserved, Map.take(path_item, methods))}
      end)
      |> Map.put_new("/versions", versions_path())

    %{
      "openapi" => document["openapi"],
      "info" => Map.put(document["info"], "title", "Fornacast GitHub-compatible subset"),
      "servers" => [%{"url" => "/api/v3"}],
      "paths" => paths,
      "components" => Map.take(document["components"], ["securitySchemes"]),
      "x-github-api-version" => version,
      "x-fornacast-source-commit" => @source_commit,
      "x-fornacast-source-blob" => source_blob,
      "x-fornacast-implemented-through-slice" => implemented_through,
      "x-fornacast-delivery-slices" => @delivery_slices
    }
  end

  defp versions_path do
    %{
      "get" => %{
        "operationId" => "meta/versions",
        "responses" => %{
          "200" => %{
            "description" => "Supported API versions",
            "content" => %{
              "application/json" => %{
                "schema" => %{
                  "type" => "array",
                  "items" => %{"type" => "string", "enum" => ["2022-11-28", "2026-03-10"]},
                  "minItems" => 2,
                  "maxItems" => 2
                }
              }
            }
          }
        }
      }
    }
  end

  defp overlay(implemented_through) do
    %{
      "source_commit" => @source_commit,
      "versions" => ["2022-11-28", "2026-03-10"],
      "servers" => %{"rest" => "/api/v3", "uploads" => "/api/uploads"},
      "implemented_through_slice" => implemented_through,
      "delivery_slices" =>
        Map.new(@delivery_slices, fn {slice, operations} ->
          {slice, operations |> Enum.map(fn {method, path} -> [method, path] end) |> Enum.sort()}
        end),
      "mutation_fields" => mutation_fields(),
      "required_mutation_fields" => required_mutation_fields(),
      "query_fields" => query_fields(),
      "divergences" => %{
        "organization_creation" => "ordinary_self_or_site_admin",
        "organization_update_scope" => "write:org",
        "personal_access_token_prefix" => "fc_pat_",
        "repository_auto_init_owner" => "delivery_slice_2",
        "repository_visibility" => ["public", "private"],
        "repository_false_only_fields" => ~w(has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
        "git_ref_writes" => "branch_refs_fast_forward_only",
        "unsupported_issue_features" => ~w(milestone type locked active_lock_reason),
        "merge_method" => "merge",
        "release_assets_server" => "/api/uploads",
        "release_archives" => nil,
        "issue_pull_release_html_url" => "corresponding_public_api_url",
        "commit_pull_diff_patch_media" => "not_acceptable"
      }
    }
  end

  defp mutation_fields do
    %{
      "POST /admin/organizations" => ~w(login admin profile_name),
      "PATCH /orgs/{org}" => ~w(name description),
      "POST /user/repos" => ~w(name description private visibility default_branch has_issues auto_init allow_merge_commit has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
      "POST /orgs/{org}/repos" => ~w(name description private visibility default_branch has_issues auto_init allow_merge_commit has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
      "PATCH /repos/{owner}/{repo}" => ~w(name description private visibility default_branch has_issues allow_merge_commit has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
      "POST /repos/{owner}/{repo}/git/refs" => ~w(ref sha),
      "PATCH /repos/{owner}/{repo}/git/refs/{ref}" => ~w(sha force),
      "PUT /repos/{owner}/{repo}/contents/{path}" => ~w(message content sha branch committer author),
      "DELETE /repos/{owner}/{repo}/contents/{path}" => ~w(message sha branch committer author),
      "POST /repos/{owner}/{repo}/issues" => ~w(title body assignee assignees labels),
      "PATCH /repos/{owner}/{repo}/issues/{issue_number}" => ~w(title body state state_reason assignee assignees labels),
      "POST /repos/{owner}/{repo}/issues/{issue_number}/comments" => ~w(body),
      "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}" => ~w(body),
      "POST /repos/{owner}/{repo}/pulls" => ~w(title head base body),
      "PATCH /repos/{owner}/{repo}/pulls/{pull_number}" => ~w(title body state base),
      "PUT /repos/{owner}/{repo}/pulls/{pull_number}/merge" => ~w(commit_title commit_message sha merge_method),
      "POST /repos/{owner}/{repo}/releases" => ~w(tag_name target_commitish name body draft prerelease),
      "PATCH /repos/{owner}/{repo}/releases/{release_id}" => ~w(name body draft prerelease),
      "POST /api/uploads/repos/{owner}/{repo}/releases/{release_id}/assets" => ~w(name label),
      "PATCH /repos/{owner}/{repo}/releases/assets/{asset_id}" => ~w(name label)
    }
  end

  defp required_mutation_fields do
    %{
      "POST /admin/organizations" => ~w(login admin),
      "POST /user/repos" => ~w(name),
      "POST /orgs/{org}/repos" => ~w(name),
      "POST /repos/{owner}/{repo}/git/refs" => ~w(ref sha),
      "PATCH /repos/{owner}/{repo}/git/refs/{ref}" => ~w(sha),
      "PUT /repos/{owner}/{repo}/contents/{path}" => ~w(message content),
      "DELETE /repos/{owner}/{repo}/contents/{path}" => ~w(message sha),
      "POST /repos/{owner}/{repo}/issues" => ~w(title),
      "POST /repos/{owner}/{repo}/issues/{issue_number}/comments" => ~w(body),
      "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}" => ~w(body),
      "POST /repos/{owner}/{repo}/pulls" => ~w(title head base),
      "POST /repos/{owner}/{repo}/releases" => ~w(tag_name),
      "POST /api/uploads/repos/{owner}/{repo}/releases/{release_id}/assets" => ~w(name)
    }
  end

  defp query_fields do
    %{
      "authenticated_repositories" => ~w(page per_page visibility affiliation type sort direction since before),
      "account_repositories" => ~w(page per_page type sort direction),
      "branches" => ~w(page per_page protected),
      "commits" => ~w(page per_page sha path author since until),
      "contents" => ~w(ref),
      "issues" => ~w(page per_page state labels assignee creator sort direction since),
      "issue_comments" => ~w(page per_page since),
      "pulls" => ~w(page per_page state head base sort direction),
      "releases" => ~w(page per_page),
      "release_assets" => ~w(page per_page)
    }
  end
end

Fornacast.OpenAPIPruner.run(System.argv())
```

The upstream upload operation uses the REST path in the source document. The checked-in overlay is authoritative that its public upload URL uses `/api/uploads`; plan 5 applies that server selection when it adds the route.

- [ ] **Step 4: Download the exact source tree and generate the two artifacts**

Run:

```bash
rm -rf /tmp/fornacast-openapi-source
git clone --filter=blob:none --no-checkout https://github.com/github/rest-api-description.git /tmp/fornacast-openapi-source
git -C /tmp/fornacast-openapi-source checkout 03ca9c1cac754ec9b8369dc75de8a8c753c6e087 -- descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json
mix run scripts/prune_github_openapi.exs -- /tmp/fornacast-openapi-source apps/fornacast_api/priv/openapi 1
```

Expected: the script exits `0`, both source blob checks pass, and the three contract documents are written. Do not commit the `/tmp` source checkout.

- [ ] **Step 5: Add deterministic golden fixture envelopes**

Each `foundation.json` fixture is a JSON object keyed by case name. Include these exact case names in both versions:

```json
{
  "versions": {"status": 200, "body": ["2022-11-28", "2026-03-10"]},
  "bad_credentials": {"status": 401, "body": {"message": "Bad credentials"}},
  "missing_user_agent": {"status": 403, "body": {"message": "User agent required"}},
  "validation_failed": {
    "status": 422,
    "body": {
      "message": "Validation Failed",
      "errors": [{"resource": "Repository", "field": "name", "code": "missing_field"}]
    }
  },
  "repository_defaults": {
    "status": 200,
    "body": {
      "private": false,
      "visibility": "public",
      "has_issues": true,
      "has_projects": false,
      "has_wiki": false,
      "has_discussions": false,
      "allow_merge_commit": true,
      "allow_squash_merge": false,
      "allow_rebase_merge": false
    }
  }
}
```

The 2022 fixture must additionally include `"rate_top_level": true`; the 2026 fixture must include `"rate_top_level": false`. Contract tests merge these partial expected maps into complete runtime responses and validate the complete result against the selected OpenAPI schema.

- [ ] **Step 6: Run the contract test and commit**

Run:

```bash
mix test --no-start apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

Expected: PASS; both pruned documents retain all five delivery-slice operation manifests, and the plan-1 subset is exact.

Commit:

```bash
git add mix.lock scripts/prune_github_openapi.exs apps/fornacast_api/mix.exs apps/fornacast_api/priv/openapi apps/fornacast_api/test/test_helper.exs apps/fornacast_api/test/openapi_contract_test.exs apps/fornacast_api/test/fixtures
git commit -m "test(api): pin GitHub REST contracts"
```

### Task 2: Scaffold the separate API application and listener

**Files:**
- Create: `apps/fornacast_api/lib/fornacast_api.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/application.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/endpoint.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/health_controller.ex`
- Create: `apps/fornacast_api/test/endpoint_test.exs`
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/prod.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write failing endpoint and dependency-boundary tests**

```elixir
defmodule FornacastAPI.EndpointTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint FornacastAPI.Endpoint

  test "health is served without browser state or GitHub policy" do
    conn = get(build_conn(), "/health")

    assert %{"status" => "ok"} = json_response(conn, 200)
    assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
    assert Plug.Conn.get_resp_header(conn, "x-github-api-version-selected") == []
    assert Plug.Conn.get_resp_header(conn, "x-ratelimit-limit") == []
  end

  test "API application has no web or transport dependency" do
    dependencies =
      :fornacast_api
      |> Application.spec(:applications)
      |> MapSet.new()

    assert MapSet.subset?(MapSet.new([:fornacast, :forge_accounts, :forge_repos, :git_core]), dependencies)
    refute MapSet.member?(dependencies, :fornacast_web)
    refute MapSet.member?(dependencies, :git_transport)
  end

  test "web application does not depend on API" do
    dependencies = :fornacast_web |> Application.spec(:applications) |> MapSet.new()
    refute MapSet.member?(dependencies, :fornacast_api)
  end
end
```

- [ ] **Step 2: Run the endpoint test and verify the application is missing**

Run:

```bash
mix test apps/fornacast_api/test/endpoint_test.exs --max-cases 1
```

Expected: FAIL because `FornacastAPI.Endpoint` and the `:fornacast_api` application do not exist.

- [ ] **Step 3: Verify the API Mix boundary and add local Phoenix macros**

Retain this dependency boundary from Task 1 in `apps/fornacast_api/mix.exs`:

```elixir
defmodule FornacastAPI.MixProject do
  use Mix.Project

  def project do
    [
      app: :fornacast_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FornacastAPI.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:forge_repos, in_umbrella: true},
      {:git_core, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.12"},
      {:open_api_spex, "~> 3.22", only: :test, runtime: false}
    ]
  end
end
```

Use local macros rather than importing web helpers:

```elixir
defmodule FornacastAPI do
  @moduledoc false

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
```

- [ ] **Step 4: Add the endpoint, application, health route, and initial router**

The endpoint contains no session, CSRF, HTML, or static plugs:

```elixir
defmodule FornacastAPI.Endpoint do
  use Phoenix.Endpoint, otp_app: :fornacast_api

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug FornacastAPI.Router
end
```

Supervise the real endpoint and leave the rate child addition to Task 6:

```elixir
defmodule FornacastAPI.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [FornacastAPI.Endpoint],
      strategy: :one_for_one,
      name: FornacastAPI.Supervisor
    )
  end
end
```

The health controller performs the same safe checks as the existing web health controller without depending on that module:

```elixir
defmodule FornacastAPI.HealthController do
  use FornacastAPI, :controller

  def show(conn, _params) do
    checks = %{
      app: :ok,
      database: database_check(),
      repository_storage: storage_check()
    }

    status = if Enum.all?(checks, fn {_key, value} -> value == :ok end), do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{status: if(status == 200, do: "ok", else: "degraded"), checks: checks})
  end

  defp database_check do
    case Ecto.Adapters.SQL.query(Fornacast.Repo, "select 1", []) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp storage_check do
    try do
      root = Fornacast.Storage.ensure_root!()
      suffix = System.unique_integer([:positive, :monotonic])
      probe = Path.join(root, ".api-health-#{suffix}")

      try do
        with :ok <- File.write(probe, "ok", [:write, :exclusive]),
             {:ok, "ok"} <- File.read(probe) do
          :ok
        else
          _reason -> :error
        end
      after
        File.rm(probe)
      end
    rescue
      _reason -> :error
    end
  end
end
```

Start with the health route only; Task 3 adds the complete API policy and catch-alls after their modules exist:

```elixir
defmodule FornacastAPI.Router do
  use FornacastAPI, :router

  scope "/", FornacastAPI do
    get "/health", HealthController, :show
  end
end
```

- [ ] **Step 5: Configure independent listeners in every environment**

Add the base endpoint in `config/config.exs`:

```elixir
config :fornacast_api, FornacastAPI.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter

config :fornacast_api,
  anonymous_rate_limit: 60,
  authenticated_rate_limit: 5_000,
  rate_window_seconds: 3_600,
  trusted_proxy_cidrs: [],
  request_target_max_bytes: 8_192,
  ordinary_json_max_bytes: 1_048_576,
  ordinary_body_total_timeout_ms: 15_000
```

Add to `config/dev.exs`:

```elixir
config :fornacast_api, FornacastAPI.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("FORNACAST_API_PORT", "4001"))],
  server: true
```

Add to `config/test.exs`:

```elixir
config :fornacast_api, FornacastAPI.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  server: false

config :fornacast_api,
  trusted_proxy_cidrs: [],
  anonymous_rate_limit: 60,
  authenticated_rate_limit: 5_000
```

Add to `config/prod.exs`:

```elixir
config :fornacast_api, FornacastAPI.Endpoint, server: true
```

In `config/runtime.exs`, parse bind addresses with `:inet.parse_address/1`, reject malformed input, and require the port for an actual release command:

```elixir
api_bind = System.get_env("FORNACAST_API_BIND_IP", "127.0.0.1")

api_ip =
  case :inet.parse_address(String.to_charlist(api_bind)) do
    {:ok, address} -> address
    {:error, reason} -> raise "invalid FORNACAST_API_BIND_IP: #{inspect(reason)}"
  end

api_port =
  fetch_runtime_env!.("FORNACAST_API_PORT", "4001")
  |> String.to_integer()

trusted_proxy_cidrs =
  System.get_env("FORNACAST_API_TRUSTED_PROXIES", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

config :fornacast_api, :trusted_proxy_cidrs, trusted_proxy_cidrs

config :fornacast_api, FornacastAPI.Endpoint,
  http: [ip: api_ip, port: api_port],
  secret_key_base: secret_key_base
```

- [ ] **Step 6: Add the API application to the release and pass endpoint tests**

Add `fornacast_api: :permanent` immediately after `fornacast_web: :permanent` in the root release list. Then run:

```bash
mix deps.get
mix test apps/fornacast_api/test/endpoint_test.exs --max-cases 1
mix compile --warnings-as-errors
```

Expected: the endpoint tests pass, both HTTP applications compile independently, and no web/API dependency cycle appears.

- [ ] **Step 7: Commit the separate API application**

```bash
git add mix.exs config apps/fornacast_api/lib/fornacast_api.ex apps/fornacast_api/lib/fornacast_api/application.ex apps/fornacast_api/lib/fornacast_api/endpoint.ex apps/fornacast_api/lib/fornacast_api/router.ex apps/fornacast_api/lib/fornacast_api/controllers/health_controller.ex apps/fornacast_api/test/endpoint_test.exs
git commit -m "feat(api): add separate REST listener"
```

### Task 3: Build the common request, validation, and error boundary

**Files:**
- Modify: `config/config.exs`
- Modify: `apps/fornacast_api/lib/fornacast_api/endpoint.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/meta_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/fallback_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/error_json.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/error.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/response.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/json.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/request_validator.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/plugs/request_context.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/plugs/request_target.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/plugs/user_agent.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/plugs/api_version.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/request_body.ex`
- Create: `apps/fornacast_api/test/request_pipeline_test.exs`

- [ ] **Step 1: Write failing request-contract tests**

Cover the complete common matrix in `request_pipeline_test.exs`:

```elixir
defmodule FornacastAPI.RequestPipelineTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint FornacastAPI.Endpoint
  @user_agent {"user-agent", "fornacast-contract-test/1.0"}

  test "missing version selects 2022 and returns common headers" do
    conn = build_conn() |> put_req_header(@user_agent) |> get("/api/v3/versions")

    assert json_response(conn, 200) == ["2022-11-28", "2026-03-10"]
    assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
    assert get_resp_header(conn, "x-github-media-type") == ["github.v3; format=json"]
    assert [request_id] = get_resp_header(conn, "x-github-request-id")
    assert request_id != ""
  end

  test "explicit supported version is selected" do
    conn =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header("x-github-api-version", "2026-03-10")
      |> get("/api/v3/versions")

    assert json_response(conn, 200) == ["2022-11-28", "2026-03-10"]
    assert get_resp_header(conn, "x-github-api-version-selected") == ["2026-03-10"]
  end

  test "unsupported version is a GitHub-shaped 400" do
    conn =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header("x-github-api-version", "2099-01-01")
      |> get("/api/v3/versions")

    assert %{
             "message" => "Bad Request",
             "documentation_url" => documentation_url
           } = json_response(conn, 400)

    assert documentation_url =~ "/rest/about-the-rest-api/api-versions"
  end

  test "missing and blank User-Agent are rejected" do
    for headers <- [[], [{"user-agent", "   "}]] do
      conn = Enum.reduce(headers, build_conn(), fn {name, value}, acc -> put_req_header(acc, name, value) end)
      conn = get(conn, "/api/v3/versions")
      assert json_response(conn, 403)["message"] == "User agent required"
    end
  end

  test "Accept negotiation allows GitHub and JSON media and rejects diff" do
    for media <- ["application/vnd.github+json", "application/json"] do
      conn =
        build_conn()
        |> put_req_header(@user_agent)
        |> put_req_header("accept", media)
        |> get("/api/v3/versions")

      assert response(conn, 200)
    end

    rejected =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header("accept", "application/vnd.github.diff")
      |> get("/api/v3/versions")

    assert json_response(rejected, 406)["message"] == "Not Acceptable"
  end

  test "unknown API and upload paths use the same sanitized 404" do
    for path <- ["/api/v3/not-a-resource", "/api/uploads/not-a-resource"] do
      conn = build_conn() |> put_req_header(@user_agent) |> get(path)
      assert json_response(conn, 404)["message"] == "Not Found"
      assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
    end
  end

  test "duplicate keys and malformed JSON are rejected" do
    for {body, reason} <- [
          {~s({"name":"one","name":"two"}), :duplicate_key},
          {~s({"name":), :malformed_json}
        ] do
      conn = Plug.Test.conn("POST", "/", body)
      conn = put_req_header(conn, "content-type", "application/json")

      assert {:error, %FornacastAPI.Error{status: 400}, ^reason, _conn} =
               FornacastAPI.RequestBody.read_json(conn, :ordinary, [])
    end
  end

  test "oversized Content-Length is rejected before body read" do
    conn =
      Plug.Test.conn("POST", "/", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-length", "1048577")

    assert {:error, %FornacastAPI.Error{status: 413}, :request_too_large, _conn} =
             FornacastAPI.RequestBody.read_json(conn, :ordinary, [])
  end

  test "request target over 8 KiB is rejected" do
    path = "/api/v3/" <> String.duplicate("a", 8_193)
    conn = build_conn() |> put_req_header(@user_agent) |> get(path)
    assert json_response(conn, 414)["message"] == "URI Too Long"
  end
end
```

- [ ] **Step 2: Run the request tests and verify common modules are missing**

Run:

```bash
mix test apps/fornacast_api/test/request_pipeline_test.exs --max-cases 1
```

Expected: FAIL because `FornacastAPI.Error`, the request plugs, and the meta/fallback controllers are undefined.

- [ ] **Step 3: Implement the sanitized error and response contract**

Use this struct and constructor surface:

```elixir
defmodule FornacastAPI.Error do
  @enforce_keys [:status, :message, :documentation_url]
  defstruct [:status, :message, :documentation_url, errors: nil, accepted_scopes: []]

  @type validation_error :: %{
          required(:resource) => String.t(),
          required(:field) => String.t(),
          required(:code) => atom(),
          optional(:message) => String.t()
        }

  @type t :: %__MODULE__{
          status: pos_integer(),
          message: String.t(),
          documentation_url: String.t(),
          errors: nil | [validation_error()],
          accepted_scopes: [String.t()]
        }

  def new(status, message, documentation_url, opts \\ []) do
    %__MODULE__{
      status: status,
      message: message,
      documentation_url: documentation_url,
      errors: Keyword.get(opts, :errors),
      accepted_scopes: Keyword.get(opts, :accepted_scopes, [])
    }
  end

  def from_domain(:invalid_credentials, url), do: new(401, "Bad credentials", url)
  def from_domain(:insufficient_scope, url), do: new(403, "Resource not accessible by personal access token", url)
  def from_domain(:forbidden, url), do: new(403, "Forbidden", url)
  def from_domain(:not_found, url), do: new(404, "Not Found", url)
  def from_domain(:git_initializer_unavailable, url), do: new(503, "Service unavailable", url)
  def from_domain({:conflict, _safe_reason}, url), do: new(409, "Conflict", url)

  def from_domain({:validation, errors}, url) do
    new(422, "Validation Failed", url, errors: errors)
  end

  def from_domain({:unavailable, _dependency}, url), do: new(503, "Service unavailable", url)
  def from_domain(_unclassified, url), do: new(500, "Internal Server Error", url)
end
```

`FornacastAPI.Response` exposes one output boundary:

```elixir
defmodule FornacastAPI.Response do
  import Plug.Conn

  def json(conn, status, body, opts \\ []) do
    conn
    |> put_assign_options(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end

  def error(conn, %FornacastAPI.Error{} = error) do
    body =
      %{message: error.message, documentation_url: error.documentation_url}
      |> maybe_put_errors(error.errors)

    json(conn, error.status, body, accepted_scopes: error.accepted_scopes)
  end

  def no_content(conn, opts \\ []) do
    conn
    |> put_assign_options(opts)
    |> send_resp(204, "")
  end

  def paginated(conn, status, body, %Fornacast.Page{} = page, opts \\ []) do
    conn
    |> FornacastAPI.Pagination.put_link_header(page, Keyword.fetch!(opts, :url))
    |> json(status, body, opts)
  end

  defp put_assign_options(conn, opts) do
    conn
    |> assign(:accepted_scopes, Keyword.get(opts, :accepted_scopes, conn.assigns[:accepted_scopes] || []))
    |> assign(:response_media_type, Keyword.get(opts, :media_type, conn.assigns[:response_media_type]))
  end

  defp maybe_put_errors(body, nil), do: body
  defp maybe_put_errors(body, errors), do: Map.put(body, :errors, errors)
end
```

`ErrorJSON.render/2` must always return the generic internal error through `FornacastAPI.Error`; it must never inspect the exception or assigns.

- [ ] **Step 4: Implement request context, version, User-Agent, and media plugs**

`RequestContext` registers response finalization before any plug may halt:

```elixir
defmodule FornacastAPI.Plugs.RequestContext do
  import Plug.Conn

  @default_version "2022-11-28"
  @default_media_type "application/vnd.github+json"

  def init(opts), do: opts

  def call(conn, _opts) do
    if api_path?(conn.request_path) do
      conn
      |> assign(:api_version, @default_version)
      |> assign(:response_media_type, @default_media_type)
      |> assign(:accepted_scopes, [])
      |> assign(:api_auth, nil)
      |> register_before_send(&put_headers/1)
    else
      conn
    end
  end

  def metadata(conn) do
    auth = conn.assigns[:api_auth]

    %{
      request_id: request_id(conn),
      api_version: conn.assigns[:api_version],
      ip_address: conn.assigns[:effective_client_ip],
      user_agent: conn |> get_req_header("user-agent") |> List.first(),
      token_id: auth && auth.api_key.id
    }
  end

  defp put_headers(conn) do
    conn
    |> put_resp_header("x-github-api-version-selected", conn.assigns.api_version)
    |> put_resp_header("x-github-media-type", "github.v3; format=json")
    |> put_resp_header("x-github-request-id", request_id(conn))
    |> put_resp_header("x-oauth-scopes", oauth_scopes(conn))
    |> put_resp_header("x-accepted-oauth-scopes", Enum.join(conn.assigns.accepted_scopes, ", "))
  end

  defp request_id(conn) do
    conn.assigns[:request_id] || List.first(get_resp_header(conn, "x-request-id")) || "unassigned"
  end

  defp oauth_scopes(%{assigns: %{api_auth: %{api_key: %{scopes: scopes}}}}) do
    scopes |> Enum.filter(fn {_scope, enabled} -> enabled end) |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(", ")
  end

  defp oauth_scopes(_conn), do: ""
  defp api_path?(path), do: String.starts_with?(path, ["/api/v3", "/api/uploads"])
end
```

`APIVersion` accepts zero or one header and sets exactly one of the two supported values. `UserAgent` rejects missing, multiple, or blank headers with the stable `403` message. `MediaType` parses comma-separated weighted Accept values, accepts `*/*`, GitHub JSON, or JSON, rejects diff/patch and other unavailable values with `406`, and requires a supported content type for body-bearing mutation methods. None of these plugs logs raw header values.

`RequestTarget` runs after `RequestContext` in the endpoint and computes `byte_size(conn.request_path <> query_suffix)` where `query_suffix` is empty or `"?" <> conn.query_string`. It returns `414` only for API/upload prefixes and leaves `/health` untouched.

- [ ] **Step 5: Implement bounded duplicate-key-safe JSON reading**

Use Elixir `JSON.decode/3` callbacks so duplicate keys are rejected at every nesting level:

```elixir
defmodule FornacastAPI.JSON do
  defmodule DuplicateKeyError do
    defexception [:key]
  end

  def decode_object(binary) when is_binary(binary) do
    decoders = %{
      object_start: fn _old_acc -> {[], MapSet.new()} end,
      object_push: fn key, value, {pairs, keys} ->
        if MapSet.member?(keys, key) do
          raise DuplicateKeyError, key: key
        else
          {[{key, value} | pairs], MapSet.put(keys, key)}
        end
      end,
      object_finish: fn {pairs, _keys}, old_acc -> {Map.new(pairs), old_acc} end
    }

    try do
      case JSON.decode(binary, nil, decoders) do
        {value, nil, rest} when rest in ["", <<>>] and is_map(value) -> {:ok, value}
        {_value, nil, _rest} -> {:error, :malformed_json}
        {:error, _reason} -> {:error, :malformed_json}
      end
    rescue
      DuplicateKeyError -> {:error, :duplicate_key}
    end
  end
end
```

`FornacastAPI.RequestBody` is a plain request-body module, never a router or endpoint plug. It has this extension contract for plan 2:

```elixir
@type admission_mfa :: {module(), atom(), [term()]}

@spec read_json(Plug.Conn.t(), atom(), keyword()) ::
        {:ok, map(), Plug.Conn.t()}
        | {:error, FornacastAPI.Error.t(), atom(), Plug.Conn.t()}

@policies %{
  ordinary: %{maximum_bytes: 1_048_576, total_timeout_ms: 15_000, idle_timeout_ms: 15_000}
}
```

An optional `:admission` callback implements `admit(conn, args)`, returning `{:ok, conn, reservation}` or `{:error, %FornacastAPI.Error{}, conn}`. If its module exports `release/1`, `read_json/3` registers a before-send release immediately. The function checks `Content-Length`, invokes admission, incrementally calls `Plug.Conn.read_body/2`, enforces elapsed total and idle time, stops before accumulated bytes exceed the policy ceiling, decodes one top-level object, and returns the sanitized reason atoms `:request_too_large`, `:request_timeout`, `:duplicate_key`, or `:malformed_json`.

Every mutation controller must authenticate, resolve an existing organization or repository, apply the role and pre-body PAT authorization described by its route, and only then call `RequestBody.read_json/3`. Organization creation authenticates the caller and validates `write:org` before reading because no target exists. Repository creation resolves and authorizes the target namespace and requires at least one repository-mutation scope before reading; after validation it enforces the scope for the requested visibility. Repository update authorizes the visible repository, required role, and stored visibility before reading, then enforces the resulting visibility after validation. This order masks private targets without consuming or parsing an attacker-controlled body.

- [ ] **Step 6: Add explicit dual-version request validators**

The facade must dispatch without converting a client value into an atom:

```elixir
defmodule FornacastAPI.RequestValidator do
  @versions %{
    "2022-11-28" => FornacastAPI.Validators.V2022_11_28,
    "2026-03-10" => FornacastAPI.Validators.V2026_03_10
  }

  def validate(version, operation, body) when is_atom(operation) and is_map(body) do
    Map.fetch!(@versions, version).validate(operation, body)
  end

  def validate_fields(body, resource, fields, required) do
    unknown = Map.keys(body) -- Map.keys(fields)
    missing = Enum.reject(required, &Map.has_key?(body, &1))

    errors =
      Enum.map(missing, &error(resource, &1, :missing_field)) ++
        Enum.map(unknown, &error(resource, &1, :unprocessable)) ++
        type_errors(body, resource, fields)

    if errors == [], do: {:ok, body}, else: {:error, {:validation, errors}}
  end

  defp type_errors(body, resource, fields) do
    Enum.flat_map(fields, fn {field, predicate} ->
      case Map.fetch(body, field) do
        :error -> []
        {:ok, value} -> if predicate.(value), do: [], else: [error(resource, field, :invalid)]
      end
    end)
  end

  defp error(resource, field, code), do: %{resource: resource, field: field, code: code}
end
```

Both version modules define their own operation clauses using these exact plan-1 bodies:

```elixir
@schemas %{
  create_organization: %{
    resource: "Organization",
    required: ~w(login admin),
    fields: %{"login" => :string, "admin" => :string, "profile_name" => :nullable_string}
  },
  update_organization: %{
    resource: "Organization",
    required: [],
    fields: %{"name" => :nullable_string, "description" => :nullable_string}
  },
  create_repository: %{
    resource: "Repository",
    required: ~w(name),
    fields: %{
      "name" => :string,
      "description" => :nullable_string,
      "private" => :boolean,
      "visibility" => :string,
      "default_branch" => :string,
      "has_issues" => :boolean,
      "auto_init" => :boolean,
      "allow_merge_commit" => :boolean,
      "has_projects" => :boolean,
      "has_wiki" => :boolean,
      "has_discussions" => :boolean,
      "allow_squash_merge" => :boolean,
      "allow_rebase_merge" => :boolean
    }
  },
  update_repository: %{
    resource: "Repository",
    required: [],
    fields: %{
      "name" => :string,
      "description" => :nullable_string,
      "private" => :boolean,
      "visibility" => :string,
      "default_branch" => :string,
      "has_issues" => :boolean,
      "allow_merge_commit" => :boolean,
      "has_projects" => :boolean,
      "has_wiki" => :boolean,
      "has_discussions" => :boolean,
      "allow_squash_merge" => :boolean,
      "allow_rebase_merge" => :boolean
    }
  }
}
```

Convert the type atoms to private predicates in each version module, then call `RequestValidator.validate_fields/4`. After type validation, reject `visibility: "internal"`, conflicting `private`/`visibility`, and any unsupported feature flag set to `true` with code `:unprocessable`. Empty update bodies are valid. Never accept a field in one version merely because the other version accepts it; the duplicated maps are intentional contract evidence.

- [ ] **Step 7: Add meta and fallback controllers and finalize the router order**

`MetaController.versions/2` returns the fixed version list. Task 6 adds the rate action and route together. `FallbackController.not_found/2` renders the standard `404` using the closest GHES overview documentation URL. Configure endpoint errors now that `ErrorJSON` exists:

```elixir
config :fornacast_api, FornacastAPI.Endpoint,
  render_errors: [formats: [json: FornacastAPI.ErrorJSON], layout: false]
```

The final endpoint order is:

```elixir
plug Plug.RequestId
plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
plug FornacastAPI.Plugs.RequestContext
plug FornacastAPI.Plugs.RequestTarget
plug FornacastAPI.Router
```

The Task 3 router is complete and contains no body-reading pipeline:

```elixir
defmodule FornacastAPI.Router do
  use FornacastAPI, :router

  pipeline :api_context do
    plug FornacastAPI.Plugs.UserAgent
    plug FornacastAPI.Plugs.APIVersion
    plug FornacastAPI.Plugs.MediaType
  end

  scope "/", FornacastAPI do
    get "/health", HealthController, :show
  end

  scope "/api/v3", FornacastAPI do
    pipe_through :api_context
    get "/versions", MetaController, :versions
    match :*, "/*path", FallbackController, :not_found
  end

  scope "/api/uploads", FornacastAPI do
    pipe_through :api_context
    match :*, "/*path", FallbackController, :not_found
  end
end
```

Tasks 4 and 6 append Authentication and RateLimit to `:api_context` in that order. Add every concrete resource route above the catch-all in its scope. Because `RequestContext` is an endpoint plug and both catch-alls pipe through `:api_context`, unlisted API paths enforce User-Agent, version, media, authentication, and rate policy and receive common headers.

- [ ] **Step 8: Run request tests and commit**

Run:

```bash
mix format apps/fornacast_api/lib apps/fornacast_api/test/request_pipeline_test.exs
mix test apps/fornacast_api/test/request_pipeline_test.exs --max-cases 1
```

Expected: all protocol-boundary tests pass; malformed input is sanitized and every API-path response has selected-version, media, and request-ID headers.

Commit:

```bash
git add config/config.exs apps/fornacast_api/lib apps/fornacast_api/test/request_pipeline_test.exs
git commit -m "feat(api): enforce GitHub request contracts"
```

### Task 4: Add token-only classic PAT authentication

**Files:**
- Modify: `apps/forge_accounts/lib/forge_accounts/api_key.ex`
- Create: `apps/forge_accounts/lib/forge_accounts/api_scope.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`
- Modify: `apps/forge_accounts/test/api_key_test.exs`
- Create: `apps/fornacast_api/lib/fornacast_api/authentication.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/plugs/authentication.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/user_controller.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Create: `apps/fornacast_api/test/authentication_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/api_key_controller.ex`
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Write failing account-domain tests for classic and token-only behavior**

Add cases with this public contract:

```elixir
assert {:ok, key, "fc_pat_" <> _ = secret} =
         ForgeAccounts.create_api_key(user, %{
           name: "automation",
           scopes: ["repo", "write:org"]
         })

assert key.scopes == %{"repo" => true, "write:org" => true}
assert {:ok, authenticated_user, authenticated_key} = ForgeAccounts.authenticate_api_key(secret)
assert authenticated_user.id == user.id
assert authenticated_key.id == key.id

assert :ok = ForgeAccounts.APIScope.authorize(key, :repository_read, :private)
assert :ok = ForgeAccounts.APIScope.authorize(key, :repository_mutation, :public)
assert :ok = ForgeAccounts.APIScope.authorize(key, :organization_read, nil)
assert :ok = ForgeAccounts.APIScope.authorize(key, :organization_mutation, nil)

assert {:error, :insufficient_scope} =
         ForgeAccounts.APIScope.authorize(public_key, :repository_read, :private)

assert {:error, :insufficient_scope} =
         ForgeAccounts.APIScope.authorize(legacy_write_key, :repository_mutation, :private)
```

Insert legacy keys directly through `%ForgeAccounts.APIKey{}` and `Fornacast.Repo.insert!/1` so `creation_changeset/2` proves that new keys reject `repo:read` and `repo:write` while stored migration keys remain usable. Cover duplicate token prefixes belonging to different users, revoked/expired/disabled owners, invalid secrets, successful `last_used_at`, and the username-checking two-argument authentication used by Git Basic.

- [ ] **Step 2: Run account tests and verify classic scopes and token-only auth fail**

Run:

```bash
mix test apps/forge_accounts/test/api_key_test.exs --max-cases 1
```

Expected: FAIL because classic scopes are rejected and `authenticate_api_key/1` plus `ForgeAccounts.APIScope` are undefined.

- [ ] **Step 3: Restrict new keys to classic scopes and add stored-scope policy**

In `APIKey`, expose both lists but validate creation against classic scopes only:

```elixir
@classic_scopes ["repo", "public_repo", "read:org", "write:org"]
@legacy_scopes ["repo:read", "repo:write"]
@type t :: %__MODULE__{}

def classic_scopes, do: @classic_scopes
def legacy_scopes, do: @legacy_scopes
```

Implement `ForgeAccounts.APIScope` with this complete decision table:

```elixir
defmodule ForgeAccounts.APIScope do
  alias ForgeAccounts.APIKey

  @type action ::
          :identity_read
          | :organization_read
          | :organization_mutation
          | :repository_read
          | :repository_mutation
          | :git_read
          | :git_write
  @type visibility :: :public | :private | nil

  def authorize(%APIKey{} = key, action, visibility) do
    accepted = accepted_scopes(action, visibility)
    if Enum.any?(accepted, &enabled?(key, &1)), do: :ok, else: {:error, :insufficient_scope}
  end

  def accepted_scopes(:identity_read, nil),
    do: ["repo", "public_repo", "read:org", "write:org", "repo:read", "repo:write"]

  def accepted_scopes(:organization_read, nil), do: ["read:org", "write:org"]
  def accepted_scopes(:organization_mutation, nil), do: ["write:org"]
  def accepted_scopes(:repository_read, :public), do: ["public_repo", "repo", "repo:read", "repo:write"]
  def accepted_scopes(:repository_read, :private), do: ["repo", "repo:read", "repo:write"]
  def accepted_scopes(:repository_mutation, :public), do: ["public_repo", "repo"]
  def accepted_scopes(:repository_mutation, :private), do: ["repo"]
  def accepted_scopes(:git_read, :public), do: ["public_repo", "repo", "repo:read", "repo:write"]
  def accepted_scopes(:git_read, :private), do: ["repo", "repo:read", "repo:write"]
  def accepted_scopes(:git_write, :public), do: ["public_repo", "repo", "repo:write"]
  def accepted_scopes(:git_write, :private), do: ["repo", "repo:write"]

  defp enabled?(%APIKey{scopes: scopes}, "public_repo") do
    scopes["public_repo"] == true or scopes["repo"] == true
  end

  defp enabled?(%APIKey{scopes: scopes}, "read:org") do
    scopes["read:org"] == true or scopes["write:org"] == true
  end

  defp enabled?(%APIKey{scopes: scopes}, scope), do: scopes[scope] == true
end
```

The accepted-scope lists are ordered minimal-first for `X-Accepted-OAuth-Scopes`; callers may preserve that order.

- [ ] **Step 4: Add token-only lookup without weakening existing lifecycle checks**

Expose these signatures in `ForgeAccounts`:

```elixir
@spec authenticate_api_key(String.t()) ::
        {:ok, User.t(), APIKey.t()} | {:error, :invalid_credentials}

@spec authenticate_api_key(String.t(), String.t()) ::
        {:ok, User.t(), APIKey.t()} | {:error, :invalid_credentials}

@spec authenticate_api_key(String.t(), String.t(), String.t()) ::
        {:ok, User.t(), APIKey.t()} | {:error, :invalid_credentials | :insufficient_scope}
```

`authenticate_api_key(secret)` derives the 15-character prefix, hashes the whole token once, queries active non-revoked and non-expired candidates joined to active `kind: :user` owners, performs `:crypto.hash_equals/2` on every same-length candidate hash, selects exactly one match, then updates `last_used_at` with the existing guarded update. The two-argument form additionally requires normalized username equality for Git Basic. Keep the three-argument form only as a compatibility wrapper for current callers until Task 5 removes scope selection from the Git controller.

Do not add an index that assumes prefixes are unique; the current prefix index is only a bounded candidate lookup.

- [ ] **Step 5: Write and run failing REST Authorization tests**

Test both accepted schemes, no credentials, malformed/multiple headers, wrong prefix, revoked/expired tokens, and an invalid token on a public endpoint:

```elixir
for scheme <- ["Bearer", "token", "bEaReR", "ToKeN"] do
  conn =
    build_conn()
    |> put_req_header("user-agent", "fornacast-contract-test/1.0")
    |> put_req_header("authorization", "#{scheme} #{secret}")
    |> get("/api/v3/user")

  assert json_response(conn, 200)["login"] == "alice"
end

invalid =
  build_conn()
  |> put_req_header("user-agent", "fornacast-contract-test/1.0")
  |> put_req_header("authorization", "Bearer fc_pat_invalid")
  |> get("/api/v3/users/alice")

assert json_response(invalid, 401)["message"] == "Bad credentials"
```

Run:

```bash
mix test apps/fornacast_api/test/authentication_test.exs --max-cases 1
```

Expected: FAIL because the authentication plug and `/user` route do not exist.

- [ ] **Step 6: Implement optional REST authentication and request auth value**

Use this request value:

```elixir
defmodule FornacastAPI.Authentication do
  @enforce_keys [:actor, :api_key]
  defstruct [:actor, :api_key]
end
```

The plug accepts exactly one header matching case-insensitive `Bearer` or `token`, followed by one non-whitespace token. With no header it leaves `api_auth: nil`. With a valid token it assigns `%FornacastAPI.Authentication{}`. Any supplied malformed, invalid, expired, revoked, or disabled-user token renders `401 Bad credentials` and halts, even if the route could be read anonymously. It never places the header or secret in an exception message.

Append the plug after `MediaType` in `:api_context`:

```elixir
plug FornacastAPI.Plugs.Authentication
```

Create `UserController` with a temporary `/user` action that requires `api_auth` and serializes only `login`; Task 10 modifies that file to use the complete versioned user serializer. Add `get "/user", UserController, :authenticated` immediately above the `/api/v3` catch-all. This makes authentication independently testable without implementing account resource serialization early.

- [ ] **Step 7: Replace settings checkboxes with classic scopes**

Render only these four checkbox names:

```elixir
for scope <- ForgeAccounts.APIKey.classic_scopes() do
  ~s(<label><input type="checkbox" name="api_key[scopes][#{scope}]" value="true"#{checked(scopes, scope)}> #{scope}</label>)
end
```

Update settings tests to create and list `%{"repo" => true, "write:org" => true}`. Assert the response never offers `repo:read` or `repo:write`. Preserve the one-time secret, no-store, expiration, revocation, and HTML-escaping assertions.

- [ ] **Step 8: Run focused account, API, and settings tests and commit**

Run:

```bash
mix test apps/forge_accounts/test/api_key_test.exs apps/fornacast_api/test/authentication_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: classic PAT creation, token-only REST authentication, hierarchy checks, legacy stored-key reads, and the classic settings flow pass.

Commit:

```bash
git add apps/forge_accounts apps/fornacast_api/lib/fornacast_api/authentication.ex apps/fornacast_api/lib/fornacast_api/plugs/authentication.ex apps/fornacast_api/lib/fornacast_api/controllers/user_controller.ex apps/fornacast_api/lib/fornacast_api/router.ex apps/fornacast_api/test/authentication_test.exs apps/fornacast_web/lib/fornacast_web/controllers/api_key_controller.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(auth): add classic PAT authentication"
```

### Task 5: Remove Git HTTP password fallback and apply classic scopes

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`
- Modify: `apps/fornacast_web/test/git_http_auth_test.exs`

- [ ] **Step 1: Replace password acceptance with the complete Git scope matrix**

Change the current `private fetch accepts account passwords` test to require `401` and the existing Basic challenge. Add table-driven discovery and receive-pack cases:

```elixir
scope_cases = [
  {"repo", :public, :read, 200},
  {"repo", :private, :read, 200},
  {"public_repo", :public, :read, 200},
  {"public_repo", :private, :read, 403},
  {"repo:read", :private, :read, 200},
  {"repo:write", :private, :read, 200},
  {"read:org", :public, :read, 403},
  {"write:org", :public, :read, 403},
  {"repo", :private, :write, 200},
  {"public_repo", :public, :write, 200},
  {"public_repo", :private, :write, 403},
  {"repo:write", :private, :write, 200},
  {"repo:read", :private, :write, 403}
]
```

For legacy scopes, insert the key directly as in Task 4. A valid PAT lacking the Git-capable scope for an otherwise visible repository returns `403`; a private repository the authenticated user cannot read remains masked as `404`; malformed, revoked, expired, disabled-owner, or otherwise invalid credentials return `401`. Keep the real Git clone test using classic `repo` and add a real public clone using `public_repo`.

- [ ] **Step 2: Run Git HTTP auth tests and verify password and classic-scope failures**

Run:

```bash
mix test apps/fornacast_web/test/git_http_auth_test.exs --max-cases 1
```

Expected: FAIL because account passwords still authenticate and the controller still asks the account context for a legacy scope before it knows repository visibility.

- [ ] **Step 3: Separate Basic PAT identity from repository-aware scope authorization**

Replace `authenticate_credential/3` with PAT-only identity authentication:

```elixir
defp authenticate_basic(encoded) do
  with {:ok, decoded} <- Base.decode64(encoded),
       [username, "fc_pat_" <> _ = secret] <- String.split(decoded, ":", parts: 2),
       {:ok, user, api_key} <- ForgeAccounts.authenticate_api_key(username, secret) do
    {:ok, user, api_key}
  else
    _reason -> {:error, :invalid_credentials}
  end
end
```

Delete the `authenticate_password/2` fallback. Authentication returns `{actor, api_key}`. After repository resolution but before `Fornacast.Access`, call:

```elixir
ForgeAccounts.APIScope.authorize(api_key, :git_read, repository.visibility)
```

or:

```elixir
ForgeAccounts.APIScope.authorize(api_key, :git_write, repository.visibility)
```

Anonymous public read remains valid only when no Authorization header is present. A supplied invalid header remains `401`. Preserve the current indistinguishability of missing and unauthorized private repositories.

- [ ] **Step 4: Pass Git HTTP auth and push regression tests**

Run:

```bash
mix test apps/fornacast_web/test/git_http_auth_test.exs apps/fornacast_web/test/git_http_push_test.exs --max-cases 1
```

Expected: password authentication is rejected; classic and legacy mappings match the fixed table; clone, fetch, push, masking, byte limits, and bookkeeping regressions pass.

- [ ] **Step 5: Commit the Git authentication migration**

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex apps/fornacast_web/test/git_http_auth_test.exs
git commit -m "fix(git): require PATs for smart HTTP"
```

### Task 6: Add trusted client-IP resolution and fixed-window rate limits

**Files:**
- Create: `apps/fornacast_api/lib/fornacast_api/client_ip.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/rate_limit.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/plugs/rate_limit.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/application.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/plugs/request_context.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/controllers/meta_controller.ex`
- Create: `apps/fornacast_api/test/rate_limit_test.exs`

- [ ] **Step 1: Write failing fixed-window and proxy tests**

Exercise an isolated counter with an injected second-based clock:

```elixir
test "anonymous and authenticated buckets use separate limits" do
  server = start_supervised!({FornacastAPI.RateLimit, name: nil, anonymous_limit: 2, authenticated_limit: 3})

  assert {:ok, %{limit: 2, used: 1, remaining: 1}} =
           FornacastAPI.RateLimit.consume({:ip, "192.0.2.10"}, 7_200, server: server)

  assert {:ok, %{limit: 3, used: 1, remaining: 2}} =
           FornacastAPI.RateLimit.consume({:token, 42}, 7_200, server: server)

  assert %{reset: 10_800} = FornacastAPI.RateLimit.peek({:token, 42}, 7_200, server: server)
end

test "an exhausted bucket remains capped until reset" do
  server = start_supervised!({FornacastAPI.RateLimit, name: nil, anonymous_limit: 1})
  assert {:ok, %{remaining: 0, used: 1}} = FornacastAPI.RateLimit.consume({:ip, "192.0.2.10"}, 10, server: server)
  assert {:error, %{remaining: 0, used: 1}} = FornacastAPI.RateLimit.consume({:ip, "192.0.2.10"}, 11, server: server)
  assert {:ok, %{remaining: 0, used: 1, reset: 7_200}} = FornacastAPI.RateLimit.consume({:ip, "192.0.2.10"}, 3_600, server: server)
end
```

Use Plug test connections to cover these effective-IP cases:

```elixir
assert "203.0.113.9" ==
         effective_ip(remote: {203, 0, 113, 9}, xff: "198.51.100.1", trusted: [])

assert "198.51.100.1" ==
         effective_ip(
           remote: {10, 0, 0, 2},
           xff: "198.51.100.1, 10.0.0.1",
           trusted: ["10.0.0.0/8"]
         )

assert "2001:db8::5" ==
         effective_ip(
           remote: {0, 0, 0, 0, 0, 65_535, 2_560, 2},
           forwarded: ~s(for="[2001:db8::5]";proto=https),
           trusted: ["::ffff:10.0.0.0/104"]
         )
```

Add endpoint cases proving normal `/versions` requests consume quota, `/rate_limit` does not, authenticated requests key by token ID, missing User-Agent still consumes the anonymous bucket, spoofed XFF is ignored, distinct clients behind a trusted proxy get distinct buckets, every response carries all six rate headers, and exhaustion returns `429 API rate limit exceeded`.

- [ ] **Step 2: Run rate tests and verify limiter/client-IP modules are absent**

Run:

```bash
mix test apps/fornacast_api/test/rate_limit_test.exs --max-cases 1
```

Expected: FAIL because `FornacastAPI.ClientIP`, `FornacastAPI.RateLimit`, and the rate headers are undefined.

- [ ] **Step 3: Implement CIDR parsing and trusted-chain selection**

Use a plain module with no process:

```elixir
defmodule FornacastAPI.ClientIP do
  defmodule CIDR do
    @enforce_keys [:family, :network, :prefix]
    defstruct [:family, :network, :prefix]
  end

  def parse_cidr!(value) when is_binary(value) do
    with [address_text, prefix_text] <- String.split(value, "/", parts: 2),
         {:ok, address} <- :inet.parse_address(String.to_charlist(address_text)),
         {prefix, ""} <- Integer.parse(prefix_text),
         family <- family(address),
         bits <- bits(family),
         true <- prefix in 0..bits do
      integer = address_to_integer(address)
      mask = mask(bits, prefix)
      %CIDR{family: family, network: Bitwise.band(integer, mask), prefix: prefix}
    else
      _reason -> raise ArgumentError, "invalid trusted proxy CIDR #{inspect(value)}"
    end
  end

  def effective(conn, cidrs) do
    trusted = Enum.map(cidrs, &normalize_cidr/1)
    remote = conn.remote_ip

    selected =
      if trusted?(remote, trusted) do
        conn
        |> forwarded_chain()
        |> select_client(remote, trusted)
      else
        remote
      end

    selected |> :inet.ntoa() |> to_string() |> String.downcase()
  end

  def trusted?(address, cidrs) do
    family = family(address)
    integer = address_to_integer(address)

    Enum.any?(cidrs, fn
      %CIDR{family: ^family, network: network, prefix: prefix} ->
        Bitwise.band(integer, mask(bits(family), prefix)) == network

      _cidr ->
        false
    end)
  end

  defp select_client([], remote, _trusted), do: remote

  defp select_client(chain, _remote, trusted) do
    chain
    |> Enum.reverse()
    |> Enum.find(&(not trusted?(&1, trusted)))
    |> case do
      nil -> hd(chain)
      address -> address
    end
  end

  defp normalize_cidr(%CIDR{} = cidr), do: cidr
  defp normalize_cidr(value), do: parse_cidr!(value)
  defp bits(:ipv4), do: 32
  defp bits(:ipv6), do: 128
  defp family(address) when tuple_size(address) == 4, do: :ipv4
  defp family(address) when tuple_size(address) == 8, do: :ipv6

  defp address_to_integer(address) do
    width = if tuple_size(address) == 4, do: 8, else: 16
    address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, width) + part end)
  end

  defp mask(_bits, 0), do: 0
  defp mask(bits, prefix), do: Bitwise.bsl(Bitwise.bsl(1, prefix) - 1, bits - prefix)
end
```

Complete `forwarded_chain/1` with these deterministic rules:

- Prefer one syntactically valid `Forwarded` header over `X-Forwarded-For`.
- Split `Forwarded` elements on commas and extract one case-insensitive `for=` parameter from each element.
- Accept quoted or unquoted IPv4, bracketed IPv6, and either form with a numeric port; reject obfuscated values beginning with `_` and the value `unknown`.
- If the selected header is malformed, return an empty chain and use `remote_ip`; do not partially trust its valid-looking prefix.
- For XFF, split on commas, trim, and require every element to parse through `:inet.parse_address/1`.
- Only consult either header when the immediate `remote_ip` is trusted.

- [ ] **Step 4: Implement the supervised fixed-window counter**

Expose this value and API:

```elixir
defmodule FornacastAPI.RateLimit do
  use GenServer

  defmodule Bucket do
    @enforce_keys [:limit, :remaining, :reset, :used, :resource]
    defstruct [:limit, :remaining, :reset, :used, resource: "core"]
  end

  @type identity :: {:token, pos_integer()} | {:ip, String.t()}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def consume(identity, now \\ System.system_time(:second), opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:consume, identity, now})
  end

  def peek(identity, now \\ System.system_time(:second), opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:peek, identity, now})
  end
end
```

The GenServer owns one private ETS table keyed by `{identity, window_start}`. `window_start = div(now, window_seconds) * window_seconds`; `reset = window_start + window_seconds`. `consume/3` increments only while used is below the configured limit and returns `{:ok, bucket}`; once used equals limit it returns `{:error, bucket}` without growing the counter. `peek/3` never changes ETS. Delete entries from older windows during each call for that identity. Production limits may be lowered in tests but never raised above `60` anonymous and `5_000` authenticated through runtime options.

Add `FornacastAPI.RateLimit` before the endpoint in `FornacastAPI.Application` so response hooks can always reach it.

- [ ] **Step 5: Add exactly-once request charging and rate headers**

`RequestContext.call/2` computes and assigns the effective client IP immediately for API/upload paths. `FornacastAPI.Plugs.RateLimit.call/2` selects `{:token, api_key.id}` after successful auth or `{:ip, effective_ip}` otherwise. It peeks only for `/api/v3/rate_limit`; every other API/upload request consumes.

Add `get "/rate_limit", MetaController, :rate_limit` immediately after `/versions` and before the `/api/v3` catch-all. Append `FornacastAPI.Plugs.RateLimit` after Authentication in `:api_context`, and modify `RequestContext.put_headers/1` to pipe the connection through `FornacastAPI.Plugs.RateLimit.put_headers/1` after the OAuth headers.

The before-send hook calls `ensure_bucket/1`: when an earlier plug halted before the rate plug, it consumes the anonymous IP bucket once; when `:rate_limit` is already assigned, it reuses it. This proves missing User-Agent, invalid version, invalid auth, malformed JSON, and fallback errors are charged exactly once.

`put_headers/1` emits:

```elixir
conn
|> put_resp_header("x-ratelimit-limit", Integer.to_string(bucket.limit))
|> put_resp_header("x-ratelimit-remaining", Integer.to_string(bucket.remaining))
|> put_resp_header("x-ratelimit-reset", Integer.to_string(bucket.reset))
|> put_resp_header("x-ratelimit-used", Integer.to_string(bucket.used))
|> put_resp_header("x-ratelimit-resource", bucket.resource)
```

An exhausted result renders `429 API rate limit exceeded` with the common closest GHES rate-limit documentation URL and still exposes the exhausted bucket.

- [ ] **Step 6: Render version-specific rate resources**

`MetaController.rate_limit/2` calls `peek/3` and returns:

```elixir
resources = %{
  core: %{
    limit: bucket.limit,
    remaining: bucket.remaining,
    reset: bucket.reset,
    used: bucket.used,
    resource: "core"
  }
}

case conn.assigns.api_version do
  "2022-11-28" -> %{resources: resources, rate: resources.core}
  "2026-03-10" -> %{resources: resources}
end
```

This is the first golden version difference. Validate both complete responses against the corresponding pruned schema.

- [ ] **Step 7: Run rate and common-pipeline tests and commit**

Run:

```bash
mix format apps/fornacast_api/lib apps/fornacast_api/test/rate_limit_test.exs
mix test apps/fornacast_api/test/rate_limit_test.exs apps/fornacast_api/test/request_pipeline_test.exs --max-cases 1
```

Expected: quota consumption, no-consume rate reads, IPv4/IPv6 proxy trust, spoof resistance, headers, reset, and `429` cases pass.

Commit:

```bash
git add apps/fornacast_api/lib apps/fornacast_api/test/rate_limit_test.exs
git commit -m "feat(api): enforce REST rate limits"
```

### Task 7: Add shared pages, public URL construction, and versioned serializers

**Files:**
- Create: `apps/fornacast/lib/fornacast/page.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/pagination.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/url.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializer.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`
- Create: `apps/fornacast_api/test/serialization_test.exs`
- Modify: `apps/fornacast_api/test/openapi_contract_test.exs`

- [ ] **Step 1: Write failing page, link, URL, and serializer tests**

Assert positive pagination, invalid strings, the `100` maximum, deterministic next/prev/first/last relations, ignored spoofed Host, and escaped path components:

```elixir
assert {:ok, [page: 2, per_page: 50]} =
         FornacastAPI.Pagination.parse(%{"page" => "2", "per_page" => "50"})

assert {:error, {:validation, [%{field: "per_page", code: :invalid}]}} =
         FornacastAPI.Pagination.parse(%{"per_page" => "101"})

page = %Fornacast.Page{entries: [:row], total: 151, page: 2, per_page: 50}
conn = FornacastAPI.Pagination.put_link_header(Plug.Test.conn(:get, "/"), page, "https://forge.test/api/v3/user/repos?type=all")
assert [link] = Plug.Conn.get_resp_header(conn, "link")
assert link =~ ~s(<https://forge.test/api/v3/user/repos?page=3&per_page=50&type=all>; rel="next")
assert link =~ ~s(rel="prev")
assert link =~ ~s(rel="first")
assert link =~ ~s(rel="last")
```

Build fixed account/repository views and assert both serializer modules return maps that validate against their selected schema. Assert every URL begins with configured `Fornacast.Config.base_url/0`, a request Host of `attacker.invalid` appears nowhere, the 2022 rate response has top-level `rate`, the 2026 response omits it, and the 2026 repository result omits exactly the properties absent from its pinned schema.

- [ ] **Step 2: Run serialization tests and verify shared page/serializer modules are absent**

Run:

```bash
mix test apps/fornacast_api/test/serialization_test.exs --max-cases 1
```

Expected: FAIL because `Fornacast.Page`, pagination, URL, and serializer modules are undefined.

- [ ] **Step 3: Add the cross-domain page value and pagination implementation**

```elixir
defmodule Fornacast.Page do
  @enforce_keys [:entries, :total, :page, :per_page]
  defstruct [:entries, :total, :page, :per_page]

  @type t(value) :: %__MODULE__{
          entries: [value],
          total: non_neg_integer(),
          page: pos_integer(),
          per_page: 1..100
        }

  def total_pages(%__MODULE__{total: 0}), do: 1
  def total_pages(%__MODULE__{total: total, per_page: per_page}), do: div(total + per_page - 1, per_page)
end
```

`Pagination.parse/1` accepts missing values as `1` and `30`, accepts only full-string positive integers, and returns GitHub validation entries with `resource: "Pagination"`, field `page` or `per_page`, and code `:invalid`. `put_link_header/3` parses the supplied canonical public URL, replaces only `page` and `per_page`, sorts query pairs by key then value, percent-encodes with `URI.encode_query/1`, and emits applicable RFC 8288 links in `next, prev, first, last` order. Do not build links from `conn.host`.

- [ ] **Step 4: Add public URL builders**

Expose these exact helpers:

```elixir
def api(path), do: join("/api/v3", path)
def upload(path), do: join("/api/uploads", path)
def web(path), do: join("", path)

def user(login), do: api("/users/#{segment(login)}")
def organization(login), do: api("/orgs/#{segment(login)}")
def repository(owner, repo), do: api("/repos/#{segment(owner)}/#{segment(repo)}")

defp join(prefix, path) do
  base = URI.parse(Fornacast.Config.base_url())
  %{base | path: prefix <> path, query: nil, fragment: nil, userinfo: nil} |> URI.to_string()
end

defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
```

Later plans extend this module for issue, pull, release, and upload URLs. They must not create parallel URL builders.

- [ ] **Step 5: Add one serializer facade and two explicit implementations**

```elixir
defmodule FornacastAPI.Serializer do
  @modules %{
    "2022-11-28" => FornacastAPI.Serializers.V2022_11_28,
    "2026-03-10" => FornacastAPI.Serializers.V2026_03_10
  }

  def render(version, resource, value, opts \\ []) when is_atom(resource) do
    @modules |> Map.fetch!(version) |> apply(:render, [resource, value, opts])
  end
end
```

Both version modules implement `render/3` for `:simple_user`, `:public_user`, `:private_user`, `:organization_simple`, `:organization_full`, `:minimal_repository`, `:repository`, `:full_repository`, `:rate_limit`, and `:error`. Each response includes every property required by its pinned schema. Use real domain values for IDs, names, descriptions, visibility, timestamps, permissions, public repository counts, bounded size, and default branch. Use compatible inert values for absent features:

```elixir
%{
  fork: false,
  forks: 0,
  forks_count: 0,
  watchers: 0,
  watchers_count: 0,
  stargazers_count: 0,
  open_issues: 0,
  open_issues_count: 0,
  has_projects: false,
  has_wiki: false,
  has_pages: false,
  has_discussions: false,
  has_downloads: false,
  allow_squash_merge: false,
  allow_rebase_merge: false,
  archived: false,
  disabled: false,
  mirror_url: nil,
  homepage: nil,
  language: nil,
  license: nil,
  topics: []
}
```

Repository URL templates are complete GitHub-style strings. For example:

```elixir
%{
  archive_url: base <> "/{archive_format}{/ref}",
  assignees_url: base <> "/assignees{/user}",
  blobs_url: base <> "/git/blobs{/sha}",
  branches_url: base <> "/branches{/branch}",
  collaborators_url: base <> "/collaborators{/collaborator}",
  comments_url: base <> "/comments{/number}",
  commits_url: base <> "/commits{/sha}",
  compare_url: base <> "/compare/{base}" <> String.duplicate(".", 3) <> "{head}",
  contents_url: base <> "/contents/{+path}",
  contributors_url: base <> "/contributors",
  deployments_url: base <> "/deployments",
  downloads_url: base <> "/downloads",
  events_url: base <> "/events",
  forks_url: base <> "/forks",
  git_commits_url: base <> "/git/commits{/sha}",
  git_refs_url: base <> "/git/refs{/sha}",
  git_tags_url: base <> "/git/tags{/sha}",
  hooks_url: base <> "/hooks",
  issue_comment_url: base <> "/issues/comments{/number}",
  issue_events_url: base <> "/issues/events{/number}",
  issues_url: base <> "/issues{/number}",
  keys_url: base <> "/keys{/key_id}",
  labels_url: base <> "/labels{/name}",
  languages_url: base <> "/languages",
  merges_url: base <> "/merges",
  milestones_url: base <> "/milestones{/number}",
  notifications_url: base <> "/notifications{?since,all,participating}",
  pulls_url: base <> "/pulls{/number}",
  releases_url: base <> "/releases{/id}",
  stargazers_url: base <> "/stargazers",
  statuses_url: base <> "/statuses/{sha}",
  subscribers_url: base <> "/subscribers",
  subscription_url: base <> "/subscription",
  tags_url: base <> "/tags",
  teams_url: base <> "/teams",
  trees_url: base <> "/git/trees{/sha}"
}
```

The three dots in the compare URL above are literal GitHub URI-template syntax, not omitted content.

Read the required-property lists from the checked-in artifacts during the contract test and fail if a serializer omits one. Keep explicit version-specific key lists in each module; do not serialize a superset and hope schema validation ignores extra fields.

- [ ] **Step 6: Validate golden responses against both pinned schemas**

Extend `openapi_contract_test.exs` with an OpenApiSpex schema validation helper that loads each checked-in document, resolves the operation response schema for the case, and validates the complete encoded/decoded map. Test at least versions, rate-limit, authenticated user, public user, organization simple/full, repository minimal/full, every stable error body, and list envelopes for both versions.

Run:

```bash
mix test apps/fornacast_api/test/serialization_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

Expected: all complete response maps validate against the selected pinned schema and the explicit 2022/2026 differences are asserted.

- [ ] **Step 7: Commit shared serialization infrastructure**

```bash
git add apps/fornacast/lib/fornacast/page.ex apps/fornacast_api/lib/fornacast_api/pagination.ex apps/fornacast_api/lib/fornacast_api/url.ex apps/fornacast_api/lib/fornacast_api/serializer.ex apps/fornacast_api/lib/fornacast_api/serializers apps/fornacast_api/test/serialization_test.exs apps/fornacast_api/test/openapi_contract_test.exs
git commit -m "feat(api): add versioned response serializers"
```

### Task 8: Add composable audit writes and organization domain operations

**Files:**
- Modify: `apps/fornacast/lib/fornacast/audit.ex`
- Modify: `apps/fornacast/test/fornacast_test.exs`
- Modify: `apps/forge_accounts/lib/forge_accounts/user.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts/organization.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`
- Modify: `apps/forge_accounts/test/forge_accounts_test.exs`

- [ ] **Step 1: Write failing composable-audit and organization-operation tests**

Prove the standardized audit helper works in one transaction:

```elixir
multi =
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:organization, Organization.changeset(%Organization{}, organization_attrs()))
  |> Fornacast.Audit.record_multi(
    :audit,
    actor,
    "organization.created",
    "organization",
    fn %{organization: organization} -> organization.id end,
    fn %{organization: organization} -> %{"login" => organization.username} end,
    request_metadata: %{request_id: "request-1"}
  )

assert {:ok, %{organization: organization, audit: audit}} = Fornacast.Repo.transaction(multi)
assert audit.target_id == Integer.to_string(organization.id)
assert audit.metadata["request_id"] == "request-1"
```

Add account-context cases for ordinary self-owned creation, site-admin creation for another active user, non-admin rejection, inactive target rejection, owner/site-admin profile update, member rejection, duplicate login, paginated organization listing, and rollback when the audit insert is invalid.

Use these public calls:

```elixir
assert {:ok, organization} =
         ForgeAccounts.create_api_organization(
           actor,
           %{"login" => "acme", "admin" => "alice", "profile_name" => "ACME"},
           request_meta
         )

assert {:ok, updated} =
         ForgeAccounts.update_organization(
           actor,
           organization,
           %{"name" => "ACME Engineering", "description" => "Compiler tools"},
           request_meta
         )

assert {:ok, %Fornacast.Page{entries: [^organization]}} =
         ForgeAccounts.list_user_organizations(actor, page: 1, per_page: 30)
```

- [ ] **Step 2: Run focused core/account tests and verify helpers are missing**

Run:

```bash
mix test apps/fornacast/test/fornacast_test.exs apps/forge_accounts/test/forge_accounts_test.exs --max-cases 1
```

Expected: FAIL because `record_multi/7`, `record_multi/8`, and the API organization operations are undefined.

- [ ] **Step 3: Add the exact composable audit helper**

The public contract is fixed for every later plan:

```elixir
@spec record_multi(
        Ecto.Multi.t(),
        Ecto.Multi.name(),
        term(),
        String.t(),
        String.t(),
        term() | (map() -> term()),
        map() | (map() -> map()),
        keyword()
      ) :: Ecto.Multi.t()

def record_multi(multi, key, actor, action, target_type, target_id, metadata, opts \\ []) do
  Ecto.Multi.insert(multi, key, fn changes ->
    target_id = resolve_multi_value(target_id, changes)
    metadata = resolve_multi_value(metadata, changes)
    request_metadata = Keyword.get(opts, :request_metadata, %{})

    attrs = %{
      actor_user_id: actor_id(actor),
      action: action,
      target_type: target_type,
      target_id: to_string(target_id),
      metadata: stringify_keys(Map.merge(metadata || %{}, request_metadata)),
      ip_address: request_metadata[:ip_address] || request_metadata["ip_address"],
      user_agent: request_metadata[:user_agent] || request_metadata["user_agent"]
    }

    AuditEvent.changeset(%AuditEvent{}, attrs)
  end)
end

defp resolve_multi_value(fun, changes) when is_function(fun, 1), do: fun.(changes)
defp resolve_multi_value(value, _changes), do: value
```

This default argument deliberately produces both `record_multi/7` and `record_multi/8`. `stringify_keys/1` converts only the fixed top-level metadata keys; it does not stringify unbounded client-controlled nested maps. Keep existing `record/6` for standalone result/failure events.

- [ ] **Step 4: Add organization profile and API-domain operations**

Add `@type t :: %__MODULE__{}` to both `User` and `Organization` so the context contracts below compile as real remote types. `Organization.profile_changeset/2` casts only `display_name` and `description`, maps the compatible `name` field before casting, trims strings, validates display-name length `1..120` when present, and description length at most `500`.

Expose these context signatures:

```elixir
@type validation_error :: %{
        required(:resource) => String.t(),
        required(:field) => String.t(),
        required(:code) =>
          :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
        optional(:message) => String.t()
      }

@type api_error :: :forbidden | :not_found | {:validation, [validation_error()]}

@spec create_api_organization(User.t(), map(), map()) ::
        {:ok, Organization.t()} | {:error, api_error()}

@spec update_organization(User.t(), Organization.t(), map(), map()) ::
        {:ok, Organization.t()} | {:error, api_error()}

@spec list_user_organizations(User.t(), keyword()) ::
        {:ok, Fornacast.Page.t(Organization.t())}

@spec get_public_user(String.t()) :: {:ok, User.t()} | {:error, :not_found}
@spec get_public_organization(String.t()) :: {:ok, Organization.t()} | {:error, :not_found}
```

`create_api_organization/3` validates `login`, `admin`, and `profile_name` before a transaction. An active ordinary actor may name only their own normalized username. An active site administrator may name any active user. Compose organization insert, owner membership insert, and `Audit.record_multi/8` in one `Ecto.Multi`; convert changeset errors to the fixed validation-entry map. `update_organization/4` requires organization owner or active site admin and composes update plus audit. On authorization, use existing membership data; do not add a second policy table.

`list_user_organizations/2` orders by `username, id`, applies offset/limit in SQL, runs a count query, and returns `%Fornacast.Page{}`. The two public getters return active, correctly typed accounts only.

- [ ] **Step 5: Pass focused audit and organization tests and commit**

Run:

```bash
mix test apps/fornacast/test/fornacast_test.exs apps/forge_accounts/test/forge_accounts_test.exs --max-cases 1
```

Expected: composable audit writes, atomic organization creation/update, authorization, tagged validation, and pagination pass on the configured test adapter.

Commit:

```bash
git add apps/fornacast/lib/fornacast/audit.ex apps/fornacast/test/fornacast_test.exs apps/forge_accounts/lib apps/forge_accounts/test/forge_accounts_test.exs
git commit -m "feat(accounts): add API organization operations"
```

### Task 9: Add repository API settings, views, authorization, and listings

**Files:**
- Create: `apps/fornacast/priv/repo/migrations/20260721000100_add_api_repository_settings.exs`
- Modify: `apps/forge_repos/lib/forge_repos/repository.ex`
- Create: `apps/forge_repos/lib/forge_repos/repository_view.ex`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/test/access_test.exs`
- Modify: `apps/forge_repos/test/forge_repos_test.exs`

- [ ] **Step 1: Write failing repository-domain tests**

Cover both boolean fields/defaults, public API default versus private browser default, conflicting visibility inputs, unsupported values, all unsupported feature flags, collaborator-complete pagination, deterministic ordering, private masking, visible forbidden writes, organization create permission, rename with unchanged storage path, default-branch existence, audit rollback, and the initializer handoff.

Use these exact public contracts:

```elixir
assert {:ok, repository} =
         ForgeRepos.create_api_repository(
           actor,
           actor,
           %{"name" => "demo", "auto_init" => false},
           request_meta
         )

assert repository.visibility == :public
assert repository.has_issues
assert repository.allow_merge_commit

assert {:error, :git_initializer_unavailable} =
         ForgeRepos.create_api_repository(
           actor,
           actor,
           %{"name" => "initialized", "auto_init" => true},
           request_meta
         )

assert {:ok, fetched} =
         ForgeRepos.fetch_authorized_repository(actor, "alice", "demo", :repository_read)

assert {:ok, %Fornacast.Page{entries: views}} =
         ForgeRepos.list_accessible_repository_views(actor, page: 1, per_page: 30)

assert Enum.any?(views, &(&1.repository.id == collaborator_repository.id))
```

- [ ] **Step 2: Run repository tests and verify new fields/operations are absent**

Run:

```bash
mix test apps/forge_repos/test/access_test.exs apps/forge_repos/test/forge_repos_test.exs --max-cases 1
```

Expected: FAIL because the migration fields, `RepositoryView`, API operations, and collaborator-complete listing are missing.

- [ ] **Step 3: Add the adapter-neutral repository settings migration**

```elixir
defmodule Fornacast.Repo.Migrations.AddAPIRepositorySettings do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add(:has_issues, :boolean, null: false, default: true)
      add(:allow_merge_commit, :boolean, null: false, default: true)
    end
  end
end
```

Add matching schema fields:

```elixir
@type t :: %__MODULE__{}

field :has_issues, :boolean, default: true
field :allow_merge_commit, :boolean, default: true
```

Include both fields in create and update casts and required validation. Do not add adapter-specific SQL or a replacement repository table.

- [ ] **Step 4: Add separate API create/update changesets**

Keep `create_changeset/2` behavior for the browser. Add:

```elixir
@api_fields [
  :slug,
  :name,
  :description,
  :visibility,
  :default_branch,
  :has_issues,
  :allow_merge_commit
]

def api_create_changeset(repository, attrs) do
  repository
  |> cast(attrs, @api_fields)
  |> validate_required([
    :owner_user_id,
    :slug,
    :name,
    :visibility,
    :storage_path,
    :default_branch,
    :has_issues,
    :allow_merge_commit
  ])
  |> validate_repository_fields()
  |> unique_constraint([:owner_user_id, :slug])
  |> unique_constraint(:storage_path)
end

def api_update_changeset(repository, attrs) do
  repository
  |> cast(attrs, @api_fields)
  |> validate_required([:slug, :name, :visibility, :default_branch, :has_issues, :allow_merge_commit])
  |> validate_repository_fields()
  |> unique_constraint([:owner_user_id, :slug])
end
```

`validate_repository_fields/1` reuses current slug/name/description/visibility/default-branch validation. API normalization maps compatible `name` to both normalized `slug` and local `name`, maps `private`/`visibility` into one enum, defaults missing visibility to public on create, and requires unsupported booleans to be `false`. `internal` is a validation error.

- [ ] **Step 5: Add the repository view and authorized fetch boundary**

```elixir
defmodule ForgeRepos.RepositoryView do
  @enforce_keys [:repository, :owner, :permissions, :size_kib]
  defstruct [:repository, :owner, :permissions, :size_kib]

  @type t :: %__MODULE__{
          repository: ForgeRepos.Repository.t(),
          owner: ForgeAccounts.User.t() | ForgeAccounts.Organization.t(),
          permissions: %{admin: boolean(), push: boolean(), pull: boolean()},
          size_kib: non_neg_integer()
        }
end
```

Expose:

```elixir
@type validation_error :: %{
        required(:resource) => String.t(),
        required(:field) => String.t(),
        required(:code) =>
          :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
        optional(:message) => String.t()
      }

@type api_error ::
        :not_found
        | :forbidden
        | :git_initializer_unavailable
        | {:validation, [validation_error()]}
        | {:unavailable, atom()}

@spec fetch_authorized_repository(User.t() | nil, String.t(), String.t(), atom()) ::
        {:ok, Repository.t()} | {:error, :not_found | :forbidden}

@spec repository_view(User.t() | nil, Repository.t()) ::
        {:ok, RepositoryView.t()} | {:error, {:unavailable, atom()}}
```

`fetch_authorized_repository/4` accepts only existing repository permission atoms. Missing rows and inaccessible private rows return `:not_found`; a visible repository with insufficient requested permission returns `:forbidden`. `repository_view/2` resolves owner and permission booleans, calls bounded `GitCore.repository_disk_usage/2` only after authorization, converts bytes to integer KiB with `div(bytes + 1023, 1024)`, and maps Git unavailability to a tagged dependency error.

- [ ] **Step 6: Implement collaborator-complete SQL pagination and filters**

Expose:

```elixir
@spec list_accessible_repository_views(User.t(), keyword()) ::
        {:ok, Fornacast.Page.t(RepositoryView.t())} | {:error, api_error()}

@spec list_account_repository_views(User.t() | nil, User.t() | Organization.t(), keyword()) ::
        {:ok, Fornacast.Page.t(RepositoryView.t())} | {:error, api_error()}
```

Build one distinct repository query that includes personal ownership, organization membership, or `repository_collaborators`, excludes soft-deleted rows, and applies visibility/access before loading a row. Supported authenticated filters are `visibility`, `affiliation`, `type`, `sort`, `direction`, `since`, and `before`; account-list filters are `type`, `sort`, and `direction`. Reject malformed supported values with validation errors; ignore unsupported query names at the HTTP boundary. Every ordering ends with `repository.id` as a stable tiebreaker. Count the filtered query before offset/limit, then build authorized views.

- [ ] **Step 7: Implement audited create/update and initializer handoff**

Expose:

```elixir
@spec create_api_repository(User.t(), User.t() | Organization.t(), map(), map()) ::
        {:ok, Repository.t()} | {:error, api_error()}

@spec update_api_repository(User.t(), Repository.t(), map(), map()) ::
        {:ok, Repository.t()} | {:error, api_error()}
```

Create verifies the actor may create in the selected personal or organization namespace, normalizes all compatible fields, and returns `:git_initializer_unavailable` before inserting a row or creating storage when `auto_init` is true. For false, compose repository insert, bare-storage initialization, and `Fornacast.Audit.record_multi/8`. If any database step after storage creation fails, remove only the newly generated opaque repository path.

Update requires repository admin for rename/settings and repository write for non-administrative implemented flags. It verifies a changed default branch through:

```elixir
GitCore.resolve_snapshot(
  ForgeRepos.absolute_storage_path(repository),
  %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/#{branch}"}
)
```

An empty repository cannot change its default branch. Rename updates `slug` and `name`, preserves `storage_path`, and makes the old route return `404`. Compose update and audit in one `Ecto.Multi`. Convert changesets and Git missing-ref results into fixed tagged validation errors.

- [ ] **Step 8: Migrate, run focused repository tests, and commit**

Run:

```bash
MIX_ENV=test mix ecto.migrate
mix test apps/forge_repos/test/access_test.exs apps/forge_repos/test/forge_repos_test.exs --max-cases 1
```

Expected: repository settings, access, collaborator listing, pagination, create/update, audit, rename, branch validation, and initializer-handoff cases pass.

Commit:

```bash
git add apps/fornacast/priv/repo/migrations/20260721000100_add_api_repository_settings.exs apps/forge_repos
git commit -m "feat(repos): add API repository operations"
```

### Task 10: Expose users and organizations through the API listener

**Files:**
- Create: `apps/fornacast_api/test/support/conn_case.ex`
- Create: `apps/fornacast_api/test/support/fixtures.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/controllers/user_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/organization_controller.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Create: `apps/fornacast_api/test/users_organizations_test.exs`

- [ ] **Step 1: Add serial endpoint support and failing resource tests**

`ConnCase` checks out the PostgreSQL sandbox when selected, truncates only foundation tables for Turso in foreign-key-safe order, forces initialized state, resets the rate counter, and sets `@endpoint FornacastAPI.Endpoint`. `Fixtures` exposes `user/2`, `organization/3`, `pat/3`, and `authorization/2`; raw secrets exist only in test return values.

Test every route and status in the plan-1 user/organization manifest, both API versions, pagination links, anonymous reads, missing/invalid credentials, classic and legacy scopes, duplicate login, ordinary self-admin rule, site-admin target rule, owner/member/admin authorization, disabled accounts, unknown fields, and scope headers.

- [ ] **Step 2: Run account endpoint tests and verify routes are absent**

Run:

```bash
mix test apps/fornacast_api/test/users_organizations_test.exs --max-cases 1
```

Expected: FAIL with `404` for the user and organization resource paths.

- [ ] **Step 3: Add exact user and organization routes**

```elixir
get "/user", UserController, :authenticated
get "/users/:username", UserController, :show
get "/user/orgs", OrganizationController, :for_authenticated_user
get "/orgs/:org", OrganizationController, :show
patch "/orgs/:org", OrganizationController, :update
post "/admin/organizations", OrganizationController, :create
```

Every route uses `:api_context`; there is no body-reading router pipeline. Order `/user/orgs` before `/users/:username` and concrete organization routes before catch-alls.

- [ ] **Step 4: Implement thin controllers with fixed scope alternatives**

Each GET action parses pagination, calls one `ForgeAccounts` operation, then calls `FornacastAPI.Serializer.render/4`. Organization creation requires authenticated `write:org` before calling `RequestBody.read_json(conn, :ordinary, [])`; it then validates the returned body and calls the domain operation that enforces the self-admin or site-admin target rule. Organization update resolves the organization and verifies owner/site-admin permission plus `write:org` before reading, then validates the body and calls the update operation. Use these accepted-scope headers:

```elixir
%{
  authenticated_user: [],
  user_organizations: ["read:org"],
  organization_mutation: ["write:org"]
}
```

`GET /user` requires any valid PAT through `APIScope.authorize(key, :identity_read, nil)`. `GET /user/orgs` requires organization read scope. Public user/org reads serialize only active correctly typed accounts. Mutation actions pass `RequestContext.metadata(conn)` into the account context and render tagged errors with the exact closest GHES operation documentation URL.

- [ ] **Step 5: Validate complete account responses against both artifacts**

Run:

```bash
mix test apps/fornacast_api/test/users_organizations_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

Expected: every user/organization route, permission, scope, pagination, error, common header, and versioned schema case passes.

- [ ] **Step 6: Commit account HTTP resources**

```bash
git add apps/fornacast_api/lib/fornacast_api/controllers/user_controller.ex apps/fornacast_api/lib/fornacast_api/controllers/organization_controller.ex apps/fornacast_api/lib/fornacast_api/router.ex apps/fornacast_api/test/support apps/fornacast_api/test/users_organizations_test.exs
git commit -m "feat(api): expose users and organizations"
```

### Task 11: Expose repository list, create, read, and update endpoints

**Files:**
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/repository_controller.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Create: `apps/fornacast_api/test/repositories_test.exs`
- Modify: `apps/fornacast_api/test/openapi_contract_test.exs`

- [ ] **Step 1: Write failing repository endpoint tests**

Cover all six route shapes, personal/org ownership, anonymous public reads, private `404` masking, visible `403`, collaborator listing, classic/legacy read scopes, classic mutation scopes, all supported list filters, invalid filter values, pagination links, both versions, public-by-default create, conflicting visibility, unsupported feature flags, rename, default-branch validation, audit metadata, and complete error bodies.

Lock the initializer boundary at HTTP level:

```elixir
response =
  api_conn(repo_secret)
  |> post("/api/v3/user/repos", %{"name" => "initialized", "auto_init" => true})

assert json_response(response, 503)["message"] == "Service unavailable"
assert ForgeRepos.get_repository("alice", "initialized") == nil
```

Also prove `auto_init: false` returns `201`, creates a real empty bare repository, and includes a canonical API URL, web `html_url`, SSH clone URL, smart-HTTP clone URL, public visibility, feature flags, and permissions.

- [ ] **Step 2: Run repository endpoint tests and verify routes are absent**

Run:

```bash
mix test apps/fornacast_api/test/repositories_test.exs --max-cases 1
```

Expected: FAIL with `404` for repository resource routes.

- [ ] **Step 3: Add exact repository routes**

```elixir
get "/user/repos", RepositoryController, :for_authenticated_user
post "/user/repos", RepositoryController, :create_for_authenticated_user
get "/users/:username/repos", RepositoryController, :for_user
get "/orgs/:org/repos", RepositoryController, :for_organization
post "/orgs/:org/repos", RepositoryController, :create_for_organization
get "/repos/:owner/:repo", RepositoryController, :show
patch "/repos/:owner/:repo", RepositoryController, :update
```

Every route uses `:api_context`; there is no body-reading router pipeline. Keep `/user/repos` before `/users/:username/repos`, `/orgs/:org/repos` before `/orgs/:org`, and all concrete routes before catch-alls.

- [ ] **Step 4: Implement list/read controller actions**

`for_authenticated_user/2` requires a valid PAT and passes validated `page`, `per_page`, `visibility`, `affiliation`, `type`, `sort`, `direction`, `since`, and `before` to `list_accessible_repository_views/2`. `public_repo` filters its result to public rows; `repo` and legacy repository scopes may include private rows the actor can read. `for_user/2` and `for_organization/2` accept only `type`, `sort`, `direction`, and pagination and pass the optional actor to `list_account_repository_views/3`.

`show/2` calls `fetch_authorized_repository/4` before `repository_view/2`. Missing or inaccessible private rows map to `404`; an invalid supplied token was already rejected as `401`. Serialize collection rows as `:repository` for authenticated `/user/repos` and `:minimal_repository` for user/org lists. Serialize one row as `:full_repository`.

Every list returns a `%Fornacast.Page{}` and uses `Response.paginated/5` with a canonical `FornacastAPI.URL.api/1` URL that retains supported filters.

- [ ] **Step 5: Implement create/update controller actions**

Both create actions authenticate first, select the target owner through `ForgeAccounts.repository_owner_by_slug_for/2`, verify namespace creation permission, and require that the PAT has `repo` or `public_repo` before reading. They then call `RequestBody.read_json(conn, :ordinary, [])`, validate `:create_repository`, derive intended visibility, enforce `APIScope.authorize(key, :repository_mutation, visibility)`, and call `ForgeRepos.create_api_repository/4` with safe request metadata. Personal creation always targets the token owner. Organization creation verifies the existing organization permission before reading and the domain operation rechecks it transactionally.

Update resolves the visible repository and authorizes the required repository role plus `:repository_mutation` against stored visibility before reading. It then calls `RequestBody.read_json(conn, :ordinary, [])`, validates `:update_repository`, authorizes the resulting visibility, and calls `update_api_repository/4`. A visibility change requires both the stored and resulting visibility checks; changing private to public cannot bypass private mutation scope.

Accepted scope headers are:

```elixir
case repository.visibility do
  :public -> ["public_repo"]
  :private -> ["repo"]
end
```

For a legacy private read response, report `["repo", "repo:read", "repo:write"]`. Create returns `201`; update returns `200`; initializer-unavailable returns `503` and includes no internal detail.

- [ ] **Step 6: Validate repository responses against both contracts**

Run:

```bash
mix test apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

Expected: repository routes, filters, access, scopes, masking, fields, pagination, version shapes, audits, and temporary initializer boundary pass.

- [ ] **Step 7: Commit repository HTTP resources**

```bash
git add apps/fornacast_api/lib/fornacast_api/controllers/repository_controller.ex apps/fornacast_api/lib/fornacast_api/router.ex apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/openapi_contract_test.exs
git commit -m "feat(api): expose repositories"
```

### Task 12: Wire development, release, and same-origin proxy startup

**Files:**
- Modify: `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`
- Modify: `apps/fornacast_web/test/fornacast_run_task_test.exs`
- Create: `deploy/nginx/fornacast.conf`
- Modify: `Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `README.md`
- Create: `apps/fornacast_api/test/proxy_contract_test.exs`
- Create: `scripts/api_proxy_smoke.sh`

- [ ] **Step 1: Write failing startup and proxy-contract tests**

Update the run-task test to assert this exact service list without deriving API dependency from the web project:

```elixir
assert Mix.Tasks.Fornacast.Run.service_applications() == [
         :fornacast,
         :forge_accounts,
         :forge_repos,
         :git_core,
         :git_transport,
         :fornacast_api,
         :fornacast_web
       ]

assert Mix.Tasks.Fornacast.Run.service_dependency_applications() == [
         :fornacast,
         :forge_accounts,
         :forge_repos,
         :git_core,
         :git_transport,
         :fornacast_api
       ]
```

The proxy test reads `deploy/nginx/fornacast.conf` and asserts `/api/v3` and `/api/uploads` share an API upstream, the `proxy_pass` has no path suffix, browser `/` uses the web upstream, forwarded headers are explicit, and neither API location rewrites the URI.

- [ ] **Step 2: Run startup/proxy tests and verify API startup and proxy files are absent**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_run_task_test.exs apps/fornacast_api/test/proxy_contract_test.exs --max-cases 1
```

Expected: FAIL because the run task omits `fornacast_api` and the Nginx configuration does not exist.

- [ ] **Step 3: Start the API before the web server in `mix fornacast.run`**

Set:

```elixir
@service_applications [
  :fornacast,
  :forge_accounts,
  :forge_repos,
  :git_core,
  :git_transport,
  :fornacast_api,
  :fornacast_web
]
@web_application :fornacast_web
```

Keep `service_dependency_applications/0` as `List.delete(@service_applications, @web_application)`. `Application.ensure_all_started(:fornacast_api)` starts its configured development endpoint on `4001`; `Mix.Tasks.Phx.Server` remains responsible for the web endpoint. Do not make web depend on API.

- [ ] **Step 4: Add the path-preserving Nginx configuration**

```nginx
upstream fornacast_web {
  server app:4890;
}

upstream fornacast_api {
  server app:4001;
}

server {
  listen 8080;
  server_name _;

  location ~ ^/(api/v3|api/uploads)(/|$) {
    proxy_pass http://fornacast_api;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  location / {
    proxy_pass http://fornacast_web;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```

There is no URI on either `proxy_pass`, so Nginx preserves both public prefixes.

- [ ] **Step 5: Make Compose expose Nginx as the public HTTP service**

Set the application container to `PORT=4890`, `FORNACAST_API_BIND_IP=0.0.0.0`, and `FORNACAST_API_PORT=4001`. Expose container ports `4890`, `4001`, and `2222`; publish only SSH from the application. Add an `nginx:1.29-alpine` service mounting `deploy/nginx/fornacast.conf` read-only, depending on app, and publishing `4000:8080`. Define the `fornacast-internal` bridge network with IPAM subnet `172.30.0.0/24`, attach both services, set `FORNACAST_API_TRUSTED_PROXIES=172.30.0.0/24`, and set default `FORNACAST_BASE_URL` to `http://localhost:4000`.

In `Dockerfile`, set web/API defaults to `4890` and `4001`, expose `4890 4001 2222`, and retain both applications in the release. Do not expose the API port as the documented public base URL.

- [ ] **Step 6: Add a live proxy smoke script and operator documentation**

Create an executable script:

```sh
#!/bin/sh
set -eu

base_url=${1:-http://127.0.0.1:4000}
user_agent=fornacast-proxy-smoke/1.0
headers=$(mktemp)
body=$(mktemp)
trap 'rm -f "$headers" "$body"' EXIT

curl -fsS -A "$user_agent" -D "$headers" "$base_url/api/v3/versions" -o "$body"
test "$(tr -d '\n ' < "$body")" = '["2022-11-28","2026-03-10"]'
grep -qi '^x-github-api-version-selected: 2022-11-28' "$headers"

status=$(curl -sS -A "$user_agent" -D "$headers" -o "$body" -w '%{http_code}' "$base_url/api/uploads/not-a-resource")
test "$status" = 404
grep -qi '^x-github-request-id:' "$headers"

curl -fsS "$base_url/health" -o "$body"
grep -q '"status":"ok"' "$body"
```

README must document internal web/API ports, public Nginx port, required User-Agent/version headers, Bearer/token PAT syntax, classic scopes, legacy read window, same-origin upload URLs, and that the first-release compatibility claim remains gated on plan 2's real `auto_init` implementation.

- [ ] **Step 7: Pass startup/proxy tests and a live Compose smoke**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_run_task_test.exs apps/fornacast_api/test/proxy_contract_test.exs --max-cases 1
docker compose config --quiet
docker compose up --build -d app nginx
scripts/api_proxy_smoke.sh http://127.0.0.1:4000
docker compose down
```

Expected: static contracts pass, Compose configuration is valid, both prefixes reach the API listener unchanged, browser health reaches web, and containers stop cleanly.

- [ ] **Step 8: Commit release and proxy wiring**

```bash
git add apps/fornacast_web/lib/mix/tasks/fornacast.run.ex apps/fornacast_web/test/fornacast_run_task_test.exs deploy/nginx/fornacast.conf Dockerfile docker-compose.yml README.md apps/fornacast_api/test/proxy_contract_test.exs scripts/api_proxy_smoke.sh
git commit -m "feat(deploy): proxy the REST listener"
```

### Task 13: Verify the foundation slice and freeze later-plan dependencies

**Files:**
- Modify: `apps/fornacast_api/test/openapi_contract_test.exs`

- [ ] **Step 1: Add final foundation contract assertions**

Assert the live Phoenix route table equals the plan-1 method/path set plus health and the two API catch-alls. Assert each live operation exists in both pinned artifacts, every serializer resource validates in both versions, no controller imports Ecto.Query, no domain application depends on an HTTP app, and authorization completes before `repository_view/2` or GitCore calls.

If this verification exposes a defect in an earlier task, stop and report the exact failing assertion and owning task; do not broaden Task 13's file scope.

Add a source assertion proving `FornacastWeb.GitHTTPController` contains no call to `ForgeAccounts.authenticate_password/2` and a runtime assertion proving the account password receives a Basic `401` challenge.

- [ ] **Step 2: Run formatting and every scoped foundation suite**

Run:

```bash
mix format --check-formatted
mix test apps/fornacast/test/fornacast_test.exs apps/forge_accounts/test apps/forge_repos/test apps/fornacast_api/test apps/fornacast_web/test/git_http_auth_test.exs apps/fornacast_web/test/git_http_push_test.exs apps/fornacast_web/test/fornacast_run_task_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
mix compile --warnings-as-errors
```

Expected: every in-scope test passes and compilation emits no warning. Stop on an out-of-scope failure rather than modifying its owner.

- [ ] **Step 3: Verify the migration and contract on both supported adapters**

Run the scoped test command once with the default Turso test configuration. Then run it against a disposable PostgreSQL database:

```bash
FORNACAST_DATABASE_ADAPTER=postgres POSTGRES_TEST_DB=fornacast_api_foundation_test mix test apps/forge_accounts/test apps/forge_repos/test apps/fornacast_api/test --max-cases 1
```

Expected: migration, transactions, audit composition, pagination, token lookup, and endpoint behavior pass on both adapters. If PostgreSQL is unavailable in the execution environment, record that external prerequisite as the only unverified item and do not replace adapter-neutral code with Turso-specific behavior.

- [ ] **Step 4: Run secret, unfinished-marker, path, and diff checks**

Run:

```bash
rg -n 'fc_pat_[A-Za-z0-9_-]{20,}|Authorization: (Bearer|token) fc_pat_' apps config deploy scripts README.md
rg -n 'inspect\((changeset|reason|error)\)|conn\.host|conn\.port' apps/fornacast_api/lib
git diff --check
git status --short
```

Expected: no raw generated PAT appears, API errors do not inspect internal values, public URL code does not use request host/port, the diff has no whitespace error, and only in-scope files are modified.

- [ ] **Step 5: Record the exact dependencies consumed by later plans**

| Later plan | Foundation contract it extends |
| --- | --- |
| Plan 2, Git data | `FornacastAPI.Router`, `RequestValidator`, `Serializer`, `Response`, `Error`, `URL`, `Pagination`, `RequestBody.read_json/3` admission hook, `ForgeAccounts.APIScope`, `ForgeRepos.fetch_authorized_repository/4`, the two pinned artifacts, and replacement of `:git_initializer_unavailable` with real Git initialization |
| Plan 3, issues | `%Fornacast.Page{}`, `RequestContext.metadata/1`, `Audit.record_multi/7-8`, repository resolution, PAT repository scope actions, common validation errors, version dispatch, and the same artifacts |
| Plan 4, pulls | All plan-3 issue identity contracts plus foundation request/response/version/scope/repository boundaries |
| Plan 5, releases | Foundation `/api/uploads` routing, raw-body bypass, public `URL.upload/1`, repository mutation scopes, error/rate headers, and the same artifacts |

No later plan may introduce a parallel authentication plug, error format, pagination struct, URL builder, serializer facade, validator facade, or OpenAPI root.

- [ ] **Step 6: Commit final contract coverage**

```bash
git add apps/fornacast_api/test/openapi_contract_test.exs
git commit -m "test(api): verify foundation contract"
```

## Foundation acceptance checklist

- [ ] `fornacast_api` starts and stops independently of `fornacast_web`.
- [ ] The release and `mix fornacast.run` start both listeners without a dependency cycle.
- [ ] `/api/v3` and `/api/uploads` reach the API listener through the same public origin without prefix stripping.
- [ ] Health is operationally useful and exempt from API policy.
- [ ] Both pinned versions, default selection, version-specific rate shape, media types, User-Agent, target/body limits, errors, and common headers are covered.
- [ ] Anonymous and authenticated rate limits, trusted proxies, spoof resistance, quota exhaustion, and no-consume rate reads are covered.
- [ ] New PATs use classic scopes, token-only REST lookup works, legacy reads stay narrow, and raw secrets remain one-time values.
- [ ] Account passwords no longer authenticate private Git smart HTTP.
- [ ] Users and organizations obey the existing shared namespace and membership model.
- [ ] Repository listings include direct collaborators and use deterministic SQL pagination.
- [ ] Repository create/update fields, public API default, feature booleans, rename, branch validation, masking, roles, scopes, and audit records are covered.
- [ ] `auto_init: true` performs no partial side effect and remains an explicit plan-2 release gate.
- [ ] Complete success and error responses validate against both checked-in pruned contracts.
