# GraphQL and `/.well-known/fornacast` Design

Date: 2026-07-31
Status: Approved

## Planning Lineage

This specification adds a **read-only** GitHub-style GraphQL endpoint and a
custom service-discovery document to Fornacast. It **revises** the GraphQL
Non-Goal in
[`2026-07-21-github-compatible-api-design.md`](./2026-07-21-github-compatible-api-design.md)
**only for this slice**: a minimal `/api/graphql` surface aligned with existing
REST read models is now in scope. Full GitHub GraphQL schema parity, mutations,
webhooks, GitHub Apps, OAuth Apps, OIDC, and related Non-Goals from that
document remain out of scope.

REST `/api/v3` contracts, PAT scopes, and domain authorization
(`ForgeAccounts` / `ForgeRepos` / `Fornacast.Access`) continue to govern
behavior; GraphQL resolvers call the same public context APIs.

## Goals

- Expose `POST|GET /api/graphql` on the `fornacast_api` listener (GitHub/GHES
  path shape, not under `/api/v3`).
- Expose public `GET /.well-known/fornacast` discovery JSON with canonical API
  URLs from `Fornacast.Config.base_url()` / `FornacastAPI.URL` (never request
  `Host`).
- Cover read-only queries for resources already available via REST:
  `viewer`, `user(login:)`, `organization(login:)`, `repository(owner:, name:)`.
- Keep nginx same-origin proxy in sync so Compose clients reach both paths on
  the public origin.

## Non-Goals

- Mutations, subscriptions, connections/pagination, issues/PRs/releases GraphQL.
- Full GitHub GraphQL schema or global node interface completeness.
- OIDC / `openid-configuration` / OAuth Apps.
- Placing GraphQL inside the versioned `/api/v3` REST pipeline
  (`X-GitHub-Api-Version`, REST media types).
- Serving discovery or GraphQL from `fornacast_web`.

## Architecture

Both surfaces live in `fornacast_api` so discovery, REST, and GraphQL share one
API listener and URL helpers.

```text
Client → nginx :4000
  ├─ /api/v3, /api/uploads, /api/graphql, /.well-known/fornacast → fornacast_api
  └─ other paths → fornacast_web
```

### `GET /.well-known/fornacast`

- Public: no User-Agent, PAT, or API-version requirement (same class as
  `/health`).
- Response: `application/json`, document version `1`:

```json
{
  "version": 1,
  "base_url": "https://forge.example",
  "api_v3": "https://forge.example/api/v3",
  "api_graphql": "https://forge.example/api/graphql",
  "api_uploads": "https://forge.example/api/uploads"
}
```

### `POST|GET /api/graphql`

- Stack: Absinthe + Absinthe.Plug.
- Pipeline: User-Agent required, optional PAT authentication, rate limit.
- No `X-GitHub-Api-Version` / GitHub REST media-type plugs.
- `GET` supports introspection; `POST` accepts
  `{"query","variables","operationName"}`.
- AuthZ: same domain boundaries as REST. Unauthorized private repositories
  resolve to `null` (existence hidden). Insufficient PAT scope after domain
  visibility surfaces as a GraphQL error, matching REST’s 403 vs 404 split.
- `viewer` requires authentication and `identity_read` scope.
- Public `user` / `organization` / public `repository` are readable without a
  token. Private repository reads require the same scopes as REST
  (`repository_read` with `:private`).
- Field naming follows GitHub GraphQL conventions (`databaseId`, `isPrivate`,
  `nameWithOwner`, …). GraphQL `id` reuses the opaque REST `node_id` encoding.

### Schema (v1)

| Query | Domain |
|-------|--------|
| `viewer` | Authenticated user (private fields only for self) |
| `user(login:)` | `ForgeAccounts.get_public_user/1` + `account_view` |
| `organization(login:)` | `ForgeAccounts.get_public_organization/1` + `account_view` |
| `repository(owner:, name:)` | `ForgeRepos.fetch_authorized_repository/4` + `repository_view` |

Resolvers stay thin: no Ecto in GraphQL modules.

## Deployment and documentation

- Nginx proxies `/api/graphql` and `/.well-known/fornacast` to the API upstream
  without path rewriting.
- Proxy contract tests and README document the public surface.
- This file is the product contract for the slice; extend it when widening the
  GraphQL schema.
