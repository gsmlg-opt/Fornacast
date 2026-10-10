# HTTP client migration to the HTTP package family

Date: 2026-10-10

Status: proposed design; implementation blocked by http_fetch#68 after the
published 0.18.1 capability audit.

## Objective and scope

Replace Fornacast-owned outbound HTTP client connections with the self-developed
HTTP package family: `http_fetch`, `http_event_source`, `http_web_socket`, and
`http_web_transport`. Preserve existing provider APIs, authorization, response
validation, deadlines, cancellation, integrity checks, and secret-safe errors.

The current callers need ordinary HTTP requests and streaming downloads/uploads.
They will use `HTTP.fetch/2`. No existing Fornacast-owned outbound SSE, WebSocket,
or WebTransport client callsite was found. The other packages are the designated
clients for their respective protocols when a real caller requires them; this
migration does not create new protocol features or empty wrapper modules.

The browser's native `fetch()` polling and inbound Phoenix/Bandit listeners are
separate from the Elixir outbound client migration. Git clone/fetch remains a Git
CLI operation under `GitCore.Remote`; replacing the Git protocol is outside this
transport change. Req/Mint dependencies owned by third-party packages remain
upstream-owned rather than being patched in Fornacast.

## Current implementation

- `ForgeGitHub.Client` builds Req requests with a custom
  `ForgeGitHub.Transport` adapter. This adapter connects through Mint HTTP/1
  directly; it does not use Req's default Finch adapter.
- `ForgeGitHub.LFS.Transport` uses Mint HTTP/1 directly for buffered requests,
  consumer-driven downloads, and streaming PUT uploads.
- `ForgeGitHub.ReleaseAssetClient` reuses LFS transport, with its own permitted
  redirect policy and a deadline shared across all hops.
- `ForgeGitHub.Pagination` and the client's response classification depend on
  `Req.Response`. Tests use `Req.Test` and injectable Mint-shaped test APIs.
- `forge_github` directly declares Req and Mint. `forge_imports` declares Req
  but has no production `Req.*` callsite; its tests rely on Req fixtures.

## Package audit and upstream gates

The packages share the upstream repository `gsmlg-dev/http_fetch`. The previous
audit covered exact Hex 0.17.2 archives; the current Fetch/runtime capability and
error-path audit uses published 0.18.1 source. These are source-audit findings,
not executed Fornacast transport acceptance tests.

The published API supports explicit `http_version: :http1`,
`redirect: :manual`, `decode_body: false`, connection/request timeouts,
AbortController, acknowledged download streams, and `duplex: :half` upload
streams. Upload chunks must be at most 65,536 bytes.

The former capability gates are resolved in the published package family:

1. [http_fetch#44](https://github.com/gsmlg-dev/http_fetch/issues/44):
   `connect_address` accepts a validated literal IPv4/IPv6 tuple while preserving
   the original URL authority, HTTP Host, TLS SNI, and certificate identity.
   Manual/error redirects are required; proxies, Unix sockets, and HTTP/3 are
   rejected for a pinned route. It does not perform address fallback or replay.
2. [http_fetch#37](https://github.com/gsmlg-dev/http_fetch/issues/37):
   `stream_response: true` returns final headers before body consumption even
   for small fixed-length responses, with acknowledged streaming backpressure.
   Bodyless responses remain buffered empty responses. The request timeout
   still covers the entire response.

Version 0.18.1 additionally fixes ExSSL certificate identity for an original
literal-IP URL dialed through a different pin. The earlier literal-IP limitation
in the FetchOptions documentation is superseded by the 0.18.1 implementation and
release change log.

One evidenced upstream gate still blocks replacing the current transports:
[http_fetch#68](https://github.com/gsmlg-dev/http_fetch/issues/68). Both transport
boundaries currently try validated IPs only until a connection succeeds, then
send the request once. Fetch 0.18.1 exposes a raw error reason without trustworthy
evidence that connection establishment failed before transmission:

- `HTTP.SocketClient.handle_new_connection/7` forwards dial failures through
  `send_error(parent, ref, reason)`.
- `initialize_legacy_owner/4` routes send failures through `fail/2`, which also
  forwards the raw reason before response headers arrive.
- `await_owner/3` exposes only `{:error, reason}`. Errors such as `:timeout` or
  `:closed` cannot establish whether request bytes may already have been sent.

Retrying another pin on these ambiguous failures could replay a mutation or
streamed upload. Selecting only the first pin would remove existing failover
behavior. Neither is the approved preservation of the transport contract.
The upstream request requires public pre-send evidence or bounded address
failover implemented before request transmission, with cancellation and one
absolute deadline retained. `ForgeGitHub.TransportTest` already covers ordered
validated-address failover, all-address failure, and exhaustion of that budget.

The repository's blocker policy requires a released upstream fix before
implementation. Dependency maintenance and unrelated release work can proceed.
The existing transport remains during the blocked state; it is not the intended
final fallback architecture. Fetch must not be retried on ambiguous errors.

`http_core` also introduces coordinated `ex_ssl` and `elixir_quic` dependencies;
`http_runtime` introduces `elixir_quic_http3`. The eventual dependency update must
check that these published artifacts compile with the project's pinned toolchain.

## Approaches and recommendation

1. **Full direct migration after upstream gates (recommended).** Replace Req and
   Mint at the existing provider boundary and adapt tests to the new client.
   This gives one production client stack and avoids a permanent compatibility
   layer. Upstream capability availability determines when implementation starts.
2. **Retain Req as a facade over Fetch.** This would preserve more response/test
   shapes initially but retain the legacy direct dependency and add an adapter.
   It still requires the upstream failover evidence and does not complete the intended
   replacement.

The recommended final design uses Fetch directly, removing Fornacast-owned Req
and Mint usage once affected callers and tests have migrated.

## Components and request flow

Keep transport ownership in `forge_github` and preserve `HostPolicy`,
`LFS.EgressPolicy`, `RequestGate`, authentication, JSON validation, rate-limit
classification, and release-asset redirect policy as application responsibilities.

For an API request:

1. Admit through the existing request gate and establish the absolute deadline.
2. Resolve and validate the hostname using the existing policy within that budget.
3. Start an HTTP/1 Fetch request with `connect_address`, `redirect: :manual`,
   `decode_body: false`, `stream_response: true`, and the remaining deadline.
   Advance to another validated IP only with upstream-provided evidence that
   the earlier attempt failed before connection establishment/transmission.
4. Obtain final headers before consuming the response body; validate encoding and
   declared length, then consume acknowledged chunks within existing byte limits.
5. Convert the completed response through existing JSON/status/domain rules and
   emit the existing request telemetry.
6. Abort and confirm resource termination on rejection, timeout, cancellation,
   or caller death. Promise-await timeout alone is not cancellation.

API transport returns `HTTP.Response` data instead of `Req.Response`; update
pagination/header access and response classification together. Use the package's
header API while preserving duplicate-header validation and ordered values where
the application requires them.

For LFS and release assets, retain the existing consumer/source contracts and
stateful error results. Use acknowledged Fetch download streams: register an ACK
reader, deliver at most 64 KiB per consumer read, and ACK only after consumption.
Apply exact declared-size/SHA-256 verification and preserve bounded pending/error
bodies. Upload the existing reader incrementally using a bounded request stream,
`duplex: :half`, and the exact Content-Length; check early EOF and excess bytes.

API and LFS calls do not automatically follow redirects or replay mutations.
Release assets retain the existing maximum of three permitted HTTPS redirects;
each hop revalidates DNS, strips Authorization, and consumes the original budget.
Address failover may occur only before connection establishment succeeds.

`http_event_source` maps to `HTTP.EventSource`, `http_web_socket` to
`HTTP.WebSocket`, and `http_web_transport` to `HTTP.WebTransport`. They represent
SSE, WebSocket, and HTTP/3 QUIC sessions respectively; WebTransport is not a
generic transport replacement for ordinary HTTPS requests. Add their direct
runtime dependencies at actual consumer boundaries when those protocols are used.

## Preserved limits and error handling

- API: request body at most 2,000,000 bytes; response body at most 200 MiB;
  cumulative response headers at most 65,536 bytes.
- Connect timeout at most five seconds; API/LFS default total budget at most
  twenty seconds; asset requests may use the existing budget up to 300 seconds.
- Downloads retain 64 KiB consumer chunks; asset pending window at most 1 MiB;
  error-body buffering at most 64 KiB.
- Reject mixed public/private DNS answers, non-identity content encoding where
  existing policy rejects it, malformed/conflicting lengths, overrun/truncation,
  and integrity mismatches using the existing typed domain errors.
- Keep URLs, tokens, and sensitive headers out of transport exception inspection
  and telemetry.

The old API path already monitors caller death; the LFS path has a timeout worker
but lacks that watchdog. Verify lifecycle behavior for the new request/stream
owners explicitly. The audit found possible unregistered-stream cleanup concerns
in upstream source, but did not reproduce them; treat resource termination as a
required verification gate rather than claiming an established upstream bug.

## Change boundary and verification

Implementation files are limited to provider transport/client/pagination,
the opaque LFS download-source state, affected provider/import test fixtures,
the existing API pull-merge integration fixture, direct dependency declarations
and the shared lockfile, and this migration documentation. No database migration
or schema change is required. Use a `codex/` branch in the project's `.trees/`
directory for implementation unless the user explicitly requests main.

Migrate the current Req.Test/Mint test seams to Fetch-compatible boundary fakes
and real loopback transport fixtures. Preserve current scenarios and add checks
for IP pinning without another DNS resolution, original TLS hostname, bounded
streaming for small/large/chunked responses, ACK backpressure, mutation non-replay,
deadline exhaustion, early rejection, upload source failures, and owner cleanup.
Require ordered failover on evidenced pre-connect failure and no second-pin
attempt after a peer accepts request bytes, a partial write, an ambiguous error,
or cancellation. Preserve the total deadline across permitted address attempts.

Run only focused PostgreSQL tests for affected `forge_github`, `forge_imports`,
and any existing downstream acceptance cases changed by the migration, with the
devenv Unix socket and `PGPORT=55432`. Run the required formatter check and compile
checks with the pinned devenv toolchain. Report any out-of-scope failures without
repairing them.

Completion requires http_fetch#68 resolved in an updated released dependency,
successful scoped checks, preservation of current streaming/security
contracts, and removal of Fornacast-owned production Req/Mint calls and obsolete
test dependencies. This document is a proposal, not implementation approval or a
claim that the migration is complete.
