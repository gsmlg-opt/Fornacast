# Admin navigation and Styx Jobs

Approved by the user on 2026-10-15: use a Gitea-like administration area, while
keeping the existing Fornacast/DuskMoon visual language.

The shared account menu exposes **Admin** only to active site administrators.
`/-/admin` opens a dedicated administration shell with a left sidebar and a
**Styx Jobs** item, pointing to `/-/admin/jobs`. The `-` namespace is deliberately
invalid as an account slug; `/admin` remains available for the existing valid
username. The administration root redirects to the first available section.

The initial page is read-only. It lists newest jobs first, 50 per page, with
queue and state filters, ID, worker, attempt/max attempts, error count, priority,
and lifecycle timestamps. Pagination retains filters. A refresh link reloads
the current view. Empty and invalid-filter states are explicit. Related GitHub
organization jobs link to the canonical synchronization task page, resolved in
batches through domain IDs. Maintenance and unrelated jobs have no invented link.
Show that queue completion is an execution step and history is subject to the
configured Styx pruning policy; domain task history is retained separately.

Browser authentication precedes a site-admin authorization plug. Anonymous
requests follow the existing login redirect; active non-admins receive 403.
Disabled/demoted users lose access on their next request. The domain listing
API also reloads persisted actor identity before authorizing, protecting direct
calls with stale/forged structs. All administration responses are private/no-store.

`ForgeImports.AdminJobs.list_jobs(actor, params)` owns read queries and a safe
projection over `Styx.Job`; controllers do not query the Repo. Only known filter
keys and string values are accepted. Page input is bounded. Raw job args, meta,
error bodies and stack traces are never returned to the web layer: Styx errors
can include exception data and secrets. Error counts remain visible.

No retry/cancel/delete/queue controls, dependency upgrades, namespace migrations,
production actions or changes to synchronization execution are in scope.

Verification covers persisted admin authorization, revoked access, safe projection,
queue/state filters, pagination and invalid input, organization task associations,
shared account navigation, no-store headers, empty rendering and preservation of
an account named admin. Use focused PostgreSQL tests only.
