# GitHub Repository and Organization Import Design

**Date:** 2026-08-25

**Status:** Approved

## Goal

Add a web-managed, one-time migration workflow from GitHub.com into Fornacast.
Users can import one repository or select repositories from a GitHub
organization. The importer copies Git branches and tags plus every GitHub
resource that the current Fornacast domain can represent, preserves GitHub
attribution through external identities, and reports unsupported data without
silently dropping it.

Imports are durable and restartable. A repository becomes visible only after
its Git data and supported metadata have been staged and validated. Replacing
an existing repository never mutates its live storage in place.

## Existing Context

Fornacast already exposes an authenticated `GET /repos/import` page, but that
page is a disabled placeholder. There is no submit route, outbound Git clone or
fetch primitive, GitHub HTTP client, GitHub credential model, external identity
model, or durable import operation.

The existing boundaries remain authoritative:

- `ForgeAccounts` owns local users, organizations, memberships, authentication,
  and account identity;
- `ForgeRepos` owns repository lifecycle, authorization, opaque storage paths,
  and repository publication;
- `ForgeIssues` owns issues, comments, labels, assignees, and the shared
  issue/pull-request number sequence;
- `ForgePulls` owns pull-request-specific state and Git analysis;
- `GitCore` owns low-level Git operations and bounded repository access; and
- `FornacastWeb` owns authenticated browser workflows.

The prior Issues and Pull Requests design deliberately excluded GitHub
credentials, imports, synchronization, and mirroring. This design introduces a
new one-time import boundary; it does not turn those resources into synchronized
mirrors.

## Scope

This design includes:

- linking multiple GitHub accounts to one local user with saved PATs;
- using either a saved PAT or a one-time PAT for an import;
- stable GitHub external identities displayed as `Github:<login>`;
- importing one GitHub repository into a personal or locally owned
  organization namespace;
- discovering and selecting accessible repositories from one GitHub
  organization;
- creating a local organization or selecting an existing organization the
  importer owns;
- per-repository conflict resolution with skip, rename, or confirmed replace;
- supervised bare-mirror Git transfer into private staging;
- supported repository metadata, issues, comments, labels, assignees, and
  representable pull requests;
- durable progress, cancellation, retry, restart recovery, and final reports;
- atomic activation of hidden imported repositories; and
- delayed reclamation of replaced or failed storage.

This design excludes:

- ongoing synchronization, polling, webhooks, and mirroring;
- GitHub Enterprise Server or arbitrary Git hosting providers;
- public REST import endpoints and Mix or release CLI commands;
- importing GitHub organization membership, teams, invitations, or
  permissions;
- granting local authorization from a linked GitHub identity;
- arbitrary clone URLs, SSH imports, and local filesystem imports;
- Git LFS objects, wiki repositories, recursively imported submodules, and
  GitHub-only refs;
- GitHub features that Fornacast does not currently model; and
- GitHub releases and release assets in this milestone. `forge_releases`
  currently provides asset-storage infrastructure, not a published release
  domain or API.

## Product Decisions

The approved decisions are:

- Import is a one-time migration, not a mirror.
- The migration imports only features already supported by Fornacast.
- Unsupported objects appear in a durable, per-item report.
- External users are not local login accounts. Their label is
  `Github:<login>`.
- A local user may link multiple GitHub identities; one GitHub identity may
  link to at most one local user.
- Identity linking changes attribution and normal author capabilities only. It
  never grants organization membership, repository access, or administrative
  permission.
- A saved PAT may be selected from the user's settings. A one-time PAT may be
  entered for a single import.
- Organization repositories are discovered and selected before execution, with
  all accessible repositories selected initially.
- Users resolve conflicts before execution. Existing repositories may be
  skipped, renamed, or replaced after explicit confirmation.
- Organizations are never replaced. A conflicting organization may be skipped,
  renamed, or explicitly selected when the importer locally owns it.
- The first release is web-only.
- Git transfer uses a staged bare mirror while metadata uses the versioned
  GitHub REST API.

## Architecture

A new umbrella application, `forge_imports`, owns import orchestration without
absorbing the existing domain models:

```text
FornacastWeb import/settings pages
                |
          ForgeImports
       /       |        \
GitHub REST  GitCore.Remote  durable runs/items/checkpoints/reports
       \       |        /
        context-owned import APIs
   ForgeAccounts / ForgeRepos / ForgeIssues / ForgePulls
                         |
                    Fornacast.Repo
```

`forge_imports` depends on the domains it coordinates. No existing domain app
depends on `forge_imports`, which prevents import concerns from becoming part of
ordinary repository, issue, or pull-request behavior.

The principal components are:

- `ForgeImports`: actor-aware public API for discovery, planning, execution,
  cancellation, retry, reporting, and recovery;
- `ForgeImports.GitHub.Client`: a GitHub.com-only, versioned REST adapter with
  authenticated pagination, classified responses, response-size limits, and
  rate-limit handling;
- `GitCore.Remote`: a provider-neutral supervised runner for creating and
  validating a bare mirror without exposing provider credentials;
- context-owned import functions that validate exact source data and contribute
  rows to caller-owned transactions without invoking ordinary user-facing
  allocation or timestamp behavior; and
- a reconciler plus `Task.Supervisor` whose workers are disposable and whose
  decisions come from durable database state.

The web layer never inserts imported rows, runs Git, stores credentials, or
coordinates recovery directly.

## Persistence

### GitHub identities

`ForgeAccounts.GitHubIdentity` stores:

- identity kind, `user` or `deleted`;
- stable GitHub numeric user ID for an ordinary identity;
- current GitHub login;
- current avatar and profile URLs after URL validation;
- optional linked local user ID;
- last verified and last observed timestamps; and
- normal insertion/update timestamps.

The 64-bit GitHub numeric ID is the unique identity key for ordinary identities.
Login is mutable and is refreshed from verified GitHub responses. Presentation
always derives `Github:<login>` from the current stored login.

Each identity row can link to at most one local user, but `local_user_id` is not
unique across identity rows because one local user may link multiple GitHub
accounts. Linking an identity already linked to another local user fails without
revealing that other account. Unlinking does not delete the external identity or
imported provenance.

GitHub may return no actor for content authored by a deleted account. Those rows
reference one non-linkable `deleted` sentinel displayed as `Github:ghost`. The
sentinel has no fabricated numeric GitHub ID and can never authenticate, link to
a local user, receive an assignment capability, or grant permission.

Imported authorship continues to reference the GitHub identity even while it is
linked. Presentation resolves the link dynamically, so linking or unlinking
does not rewrite historical content.

### GitHub credentials

`ForgeAccounts.GitHubCredential` stores at most one active saved PAT for a
linked identity:

- local user and GitHub identity IDs;
- encrypted ciphertext, nonce, authentication tag, and encryption-key ID;
- last successful verification timestamp;
- classified credential status; and
- normal timestamps.

The encryption keyring is dedicated runtime secret material, separate from the
database, Concord configuration, `SECRET_KEY_BASE`, and stored ciphertext.
Encryption is AEAD with record-bound authenticated data containing the
credential ID, local user ID, provider, and GitHub numeric ID. One configured
key ID is active for writes; older configured keys remain available for reads
during controlled rotation and re-encryption.

When no valid credential keyring is configured, the credential vault fails
closed and every GitHub settings/import mutation returns a sanitized service
unavailable state. The rest of the forge remains operational, and no plaintext
or fallback encryption key is generated or derived implicitly.

The raw PAT is never recoverable through a context API intended for web
presentation. A narrow worker-only checkout function decrypts it into the
calling process for one bounded operation.

A one-time PAT uses the same encrypted envelope on the import run. It creates no
settings credential and no identity link. Its encrypted fields are cleared on
every terminal run transition, including completion with warnings, failure,
cancellation, and unrecoverable startup cleanup.

Deleting a saved PAT retains the verified identity link. Unlinking the GitHub
identity is a distinct transaction that clears the link and deletes its saved
credential, while retaining the external identity and provenance. Historical
attribution then renders as `Github:<login>` again. Any unfinished run using the
deleted credential moves to `awaiting_credential`.

### Imported attribution

Locally created content continues to reference local users. Imported GitHub
content references GitHub identities:

- issues gain external-author attribution;
- issue comments gain external-author attribution;
- issue assignees can reference either a local user or GitHub identity; and
- pull requests gain external merger attribution.

Database constraints enforce exactly one author identity for authored rows,
zero or one merger identity as appropriate, and exactly one assignee identity
per assignment. These are ID references across contexts, not Ecto associations
that couple the contexts.

When a GitHub identity is linked, ordinary author capabilities apply to the
linked local user. Imported external assignees receive no access, notification,
or organization membership from the assignment.

### Import runs and repository items

`ForgeImports.ImportRun` stores:

- importing local actor;
- optional predecessor run ID for a user-requested retry;
- source kind, `repository` or `organization`;
- verified GitHub identity and credential source;
- source organization/repository identity;
- destination organization decision;
- run state, cancellation intent, counts, warnings, and timestamps;
- encrypted one-time credential envelope when applicable; and
- sanitized request and audit metadata.

`ForgeImports.RepositoryItem` stores one selected source repository:

- optional predecessor item ID;
- 64-bit GitHub repository numeric ID and source full name;
- discovered source metadata and observation timestamps;
- intended destination owner and slug;
- immutable conflict decision for the current attempt once running;
- exact replacement target ID and conflict fingerprint when applicable;
- hidden repository ID and opaque staged storage path;
- current phase, lease, attempt, failure classification, and checkpoints;
- source Git observations and validated publication evidence; and
- imported, skipped, warning, and failure counts.

Separate attempt, object-mapping, checkpoint, and report-entry rows retain
history without growing one mutable operation row into an unbounded document.
Source mappings are unique by hidden repository ID, GitHub source repository
ID, object kind, and stable GitHub object ID. A page checkpoint commits in the
same transaction as the imported rows and their mappings.

### Repository lifecycle

Repositories gain an explicit lifecycle state with `importing`, `ready`, and
`tombstoned` values, plus a positive generation. Existing and ordinarily
created repositories are `ready` at generation one. Import creates an
`importing` shadow repository with a generated internal slug and new opaque
hashed storage path. For replacement, its intended generation is one greater
than the approved target generation. All repository lookup, listing,
authorization, REST, GraphQL, Git transport, and browser paths require `ready`
and a nil `deleted_at` before storage access.

Publication changes the replaced row to `tombstoned` and sets `deleted_at`; the
shadow becomes `ready` at its intended generation. Ordinary writer-fence calls
carry the repository ID and generation observed during authorization, then
reload both after acquiring the fence. A queued caller fails if lifecycle or
generation no longer matches, so it cannot write through a stale row after
replacement.

The desired owner and final slug remain on the import item until publication.
This permits metadata to be imported incrementally under the shadow repository
ID while keeping it unreachable.

## Identity Linking Workflow

The settings flow accepts a PAT only over the existing CSRF-protected local
session. It then:

1. calls GitHub's authenticated-user endpoint with the PAT;
2. validates and normalizes the returned numeric ID, login, and safe profile
   fields;
3. rejects an identity already linked to another local user;
4. creates or refreshes the GitHub identity;
5. encrypts and saves or replaces the PAT; and
6. records a sanitized `github.account.linked` or
   `github.credential.replaced` audit event.

GitHub identity verification does not prove repository or organization access.
Discovery separately checks the selected credential against the requested
source and reports missing GitHub permissions.

Credential deletion, unlinking, and reverification are independent operations.
Expired or revoked PATs mark the saved credential invalid but leave the identity
link intact.

## Import Lifecycle

Run transitions are:

```text
discovering -> awaiting_resolution | failed | canceled
awaiting_resolution -> ready | awaiting_credential | canceled
ready -> running | awaiting_credential | canceled
running -> awaiting_credential | completed | completed_with_warnings | failed
running -> cancel_requested
awaiting_credential -> awaiting_resolution | ready | running | cancel_requested | canceled
cancel_requested -> canceled | completed | completed_with_warnings
```

The run records the state to resume after credential replacement. `completed`
means every selected item published without warnings. `completed_with_warnings`
means the run reached a deliberate terminal result with warnings: at least one
item published while another was skipped, failed, canceled, drifted, or reported
unsupported data, or every runnable item was intentionally skipped. `failed`
means nothing published, at least one runnable item failed, and the run cannot
progress without a successor retry. `canceled` may still contain repositories
that published before cancellation won. The plan must contain at least one
selected repository before it can start; unselected repositories do not affect
terminal aggregation.

Repository-item states are:

```text
queued
  -> staging_git
  -> git_staged
  -> staging_metadata
  -> ready_to_publish
  -> publishing
  -> published
  -> completed
```

Nonterminal item detours are `awaiting_resolution`, `awaiting_credential`, and
`cancel_requested`; terminal item outcomes are `completed`, `skipped`,
`canceled`, and `failed`. A deleted, expired, revoked, or insufficient saved
credential moves unfinished work to `awaiting_credential`; the owner may select
a replacement saved credential or enter a one-time PAT. Terminal run and item
states are immutable. A user-requested retry creates a successor run containing
only retryable unpublished items and links every new item to its predecessor. In
one ownership transaction, the successor may adopt the predecessor's hidden
repository, validated staging, and proven checkpoints; published items are never
copied or rerun. The predecessor report remains unchanged. A one-time credential
is never carried into the successor, so the user must select or enter a
credential again.

The database is authoritative. Worker PIDs, task results, and in-memory queues
are never completion evidence.

### Discovery

Repository discovery accepts either `owner/repository` or a canonical
`https://github.com/owner/repository` URL. The parser extracts and validates the
two path components, permits only an optional `.git` suffix or trailing slash,
and rejects every additional path component. It discards URL query, fragment,
user information, and presentation spelling. Network code receives the
normalized components, not the submitted URL.

Organization discovery:

- verifies organization visibility through the selected credential;
- loads every repository visible to that credential through REST pagination;
- presents all repositories selected initially;
- records GitHub IDs rather than relying on mutable names; and
- makes no local organization or repository mutation.

Discovery computes local normalization, validation failures, namespace
collisions, repository collisions, unsupported source attributes, and initial
credential capability warnings before execution.

Source names are never silently truncated or attached to a normalized collision.
When a GitHub organization or repository name cannot satisfy local validation,
the plan requires an explicit valid destination slug.

Destination namespaces also pass the shared reserved-root-name validation used
for new accounts. Names that collide with authenticated, setup, health,
settings, static, repository-creation, or organization-creation route prefixes
require a different local slug. Existing grandfathered reserved namespaces
cannot be selected as import destinations.

### Conflict resolution

For an organization namespace conflict, the user may:

- choose another valid local slug;
- skip the organization import; or
- select the existing organization when the local actor is its owner.

Organizations are never replaced or automatically merged by matching slug.

For each repository conflict, the user may:

- skip the source repository;
- choose a different valid local slug; or
- replace the exact existing repository after typing its full local name.

The UI supports applying one action to similar conflicts, but persists the
resolved decision on every item. Starting an attempt freezes its decisions. If
destination drift requires new conflict resolution, the old attempt and its
decision remain immutable while a new decision revision starts a new attempt.

A replace decision records the exact repository ID, owner ID, storage path,
update observation, and relevant Git-write observation. Publication reloads and
locks that target. Drift returns the item to `awaiting_resolution`; publication
never selects a replacement target by slug alone.

## Git Transfer

`GitCore.Remote` performs a bare mirror into a new private staging directory.
It does not run inside a web request process.

The runner must:

- construct only `https://github.com/<owner>/<repository>.git` remotes from
  verified components;
- use a supervised OS process group so timeout or cancellation terminates every
  descendant;
- avoid checkouts, hooks, submodule recursion, shell interpolation, and
  user/system Git configuration;
- disable `file`, `ext`, and other external-helper protocols;
- provide the PAT through an ephemeral credential broker rather than a URL,
  argument, environment value, or persistent credential helper;
- capture bounded, sanitized diagnostic output;
- monitor wall-clock and staged-disk limits; and
- use a `0700` staging directory outside any ready repository path.

After clone, validation proves that the result is a physical bare repository,
that objects and publishable refs are readable, and that configured hard limits
are satisfied. Only `refs/heads/*` and `refs/tags/*` remain in the repository at
activation. GitHub pull refs, notes, replacement refs, and other provider-only
refs are removed before validation completes. A pull request whose required
objects would become unreachable after that removal is unsupported.

The importer removes the source remote and fetch configuration after transfer.
The resulting Fornacast repository is independent and contains no credential or
automatic synchronization path.

For a nonempty repository, the bare `HEAD` is set to the imported default branch
and validation requires that branch to exist. An empty GitHub repository remains
a supported empty bare repository with its configured default-branch metadata
but no resolved `HEAD` target.

Git LFS pointer blobs remain ordinary Git blobs; LFS objects are not downloaded.
Submodule declarations remain files in the repository, but their repositories
are not recursively imported. Both conditions appear in the report when
detected.

## GitHub REST Import

The GitHub client uses:

- fixed `https://api.github.com` endpoints;
- the explicit `2026-03-10` API version;
- the recommended GitHub JSON media type;
- a non-empty, product-specific `User-Agent`;
- authenticated `Link`-header pagination; and
- response and request deadlines appropriate to each resource.

Requests for one credential are serialized to reduce secondary-rate-limit risk.
The client reads rate-limit headers from every response. Primary or secondary
rate limits move the item into a durable wait with a calculated next-attempt
time rather than spinning or failing immediately.

Conditional requests may be used during recovery, but a `304` is useful only
when the associated page checkpoint is already durable. The importer never
advances from an HTTP cache entry alone.

A GitHub repository remains live during a REST import. This design therefore
provides a recorded, best-effort source snapshot rather than claiming one global
GitHub transaction. The item records observed source timestamps and ref OIDs.
When imported metadata references an object missing from the staged mirror, it
performs one bounded refetch and revalidation. Remaining drift becomes an
explicit warning or typed failure according to whether the affected supported
object can be represented safely.

## Supported Data Mapping

Within one shadow repository, metadata is committed in dependency order:

1. GitHub identities;
2. repository labels;
3. canonical issue rows, including pull-backed issue identities;
4. comments, label assignments, and assignees;
5. pull-request-specific rows; and
6. the repository issue/pull number sequence.

Every source numeric ID uses a 64-bit database field. A dependent page cannot
checkpoint before all rows and source mappings required by that page commit.

### Organization

The importer maps the GitHub organization login into the chosen local slug and
imports the supported display name and description. The GitHub organization ID,
source URL, and observation metadata remain import provenance rather than local
organization profile fields. Unsupported avatar/profile fields appear in the
report. The importing local user becomes the sole local owner of a newly created
organization.

When GitHub provides no organization display name, the local display name falls
back to the chosen local slug.

A new organization is created transactionally after its plan is frozen and
before repository shadow rows are created. It remains as a valid local
organization if every repository later fails or the run is canceled; the report
makes that outcome explicit. Selecting an existing organization preserves its
local display name, description, memberships, and access policy rather than
overwriting them from GitHub.

GitHub members, owners, teams, invitations, outside collaborators, roles, and
permissions are not imported. Linking a member's GitHub identity later does not
create a local membership.

### Repository

Supported repository fields are:

- chosen local slug and source name;
- description;
- `public` or `private` visibility;
- default branch;
- Issues enablement; and
- merge-commit enablement.

Visibility defaults to the source mapping, but the user may explicitly select
local `public` or `private` during plan review. GitHub `internal` visibility
maps to local `private` with a warning. Imported
forks become independent local repositories and retain source provenance without
setting a local fork relationship. Archived/read-only state, templates, topics,
homepage, license metadata, security settings, projects, wiki/discussions
flags, squash/rebase settings, and GitHub permissions are reported as
unsupported.

A replacement changes Git data, supported repository fields, issues, and pull
requests. It preserves the chosen local owner, local collaborators, local access
policy, and audit history. It does not copy GitHub organization permissions into
local authorization.

### Issues and comments

Dedicated import changesets preserve:

- exact repository-local number;
- title and body;
- open or closed state and representable state reason;
- source creation, update, and close timestamps;
- author identity;
- labels and external/local assignees; and
- issue and pull-request conversation comments with their source creation and
  update timestamps.

Ordinary creation APIs are not reused because they allocate new numbers and
current timestamps. Imported rows still pass string, NUL-byte, length, state,
and repository-identity validation.

Milestones, reactions, locking, projects, issue types, sub-issues, timeline
events, and attachment bytes are unsupported. Markdown remains subject to the
normal Fornacast sanitizer. GitHub attachment URLs remain external links and are
reported rather than downloaded.

After staging, the repository number sequence becomes one greater than the
highest imported issue or pull-request number. It never uses `max(number) + 1`
for later ordinary allocations.

### Labels and assignees

Repository labels are imported before assignments and use stable GitHub IDs for
replay. Label names, colors, and descriptions pass local validation. Conflicting
source labels that cannot normalize distinctly are reported rather than merged
silently.

Imported assignees reference GitHub identities. They are presentation metadata,
not collaborators, members, or notification subscriptions.

### Pull requests

Every imported pull request retains the canonical shared
`ForgeIssues.Issue` row. The importer additionally preserves, when
representable:

- base and head branch names;
- base and head OIDs;
- merge state and timestamp;
- merge commit OID;
- external merger identity; and
- ordinary conversation comments, labels, and assignees.

Pull requests import only when canonical same-repository head and base branches
remain live and their required Git objects exist. A deleted source or target
branch makes even a closed historical pull request unsupported because current
pull-request reads and analysis resolve live canonical refs.

Cross-repository and fork pull requests, drafts, reviews, approvals, inline
review comments, requested reviewers, and squash/rebase semantics are not
representable by the current pull domain and are skipped with explicit report
entries. Unsupported pull requests are not converted into ordinary issues.

### Releases and other unsupported data

GitHub releases, source archives, and release assets are reported as unsupported
for this milestone. They are not sent directly to `ForgeReleases.AssetStorage`
because no Fornacast release record currently owns those bytes.

GitHub Actions, packages, deployments, environments, projects, discussions,
wikis, pages, security alerts, stars, watchers, notifications, webhooks, deploy
keys, repository secrets, and settings outside the supported mapping are also
excluded.

## Publication and Replacement

Before `ready_to_publish`, only the hidden repository, staged storage, and
import-owned rows can change. The live namespace remains untouched.

Publication acquires the destination repository write fence and resolves any
pending durable Git-write or merge operations. Write-fence callers must reload
repository lifecycle and generation after acquisition so a request queued
before replacement cannot later mutate the tombstoned repository.

For a new repository, one transaction:

1. rechecks destination authorization and slug availability;
2. changes the hidden repository to the final owner and slug;
3. marks it ready;
4. records the publication marker and audit event; and
5. marks the item published.

For replacement, one transaction:

1. locks and revalidates the exact approved target;
2. copies local collaborator relationships required by the preserved local
   authorization policy to the hidden repository;
3. tombstones the old repository, freeing its active owner/slug key;
4. activates the hidden repository under that owner and slug;
5. records the replacement marker and audit event; and
6. marks the item published.

The active namespace constraint remains the existing partial unique index on
`(owner_user_id, slug)` where `deleted_at IS NULL` for both supported database
adapters. Setting `deleted_at` on the old row and activating the shadow therefore
hands the owner/slug key over atomically without renaming or deleting history.

The imported repository already owns its new opaque storage path, so publication
does not rename or overwrite the old directory. Database namespace activation
is the visibility boundary.

Replacement activates the shadow repository's local numeric and node identity;
the old repository ID is not reused. The owner/slug URL remains stable, while
the report and audit event record both old and new IDs so API consumers can
observe that an explicit replacement created a new local repository identity.

Readers that resolved the old repository before publication may finish using
its old path. New lookups resolve only the activated repository. The old row and
storage remain tombstoned until a grace period longer than every bounded Git
operation has elapsed and cleanup proves no relevant operation lease remains.

A completed item means publication evidence, report rows, and audit records are
durable. Delayed old-storage reclamation is not required for correctness.

## Recovery, Cancellation, and Cleanup

`ForgeImports.RecoverySupervisor` uses a `Task.Supervisor` and reconciler, based
on the existing durable pull-merge recovery pattern. Repository items use
`Fornacast.OperationLease` for exclusive claims with renewal and loss detection.

Recovery writes intent before external effects and records proof afterward. It
classifies an incomplete phase using durable facts:

- staged directory and bare-repository validation;
- committed source-object mappings and checkpoints;
- hidden repository lifecycle;
- publication marker and current active namespace; and
- terminal report and credential-cleanup evidence.

An organization run is atomic per repository, not across all selected
repositories. One failure does not roll back published siblings.

Cancellation is cooperative:

- stop scheduling queued items;
- terminate active Git process groups;
- check intent between REST pages and object batches; and
- discard unpublished shadows and staging after durable cancellation.

Publication is not interrupted. If it commits before cancellation wins, that
repository is successful and remains published.

A successor retry preserves prior attempts, terminal items, and failure
evidence. It adopts only checkpoints whose rows and mappings committed
atomically. It never treats a stale worker, partial page, or directory existence
as success.

Failed and canceled staging is reclaimed after recovery proves it is not owned
by a live lease. One-time credential ciphertext is cleared before the run enters
a terminal state. A startup reconciler handles any pre-terminal run whose worker
died before cleanup.

## Security

### Outbound request boundary

The importer is GitHub.com-only. It constructs API and Git URLs internally from
validated owner/repository components. It does not accept a destination host.

Every HTTP redirect must remain HTTPS and match a route-specific host allowlist.
Resolved loopback, private, link-local, multicast, and otherwise non-public
addresses are rejected. Redirect counts and response sizes are bounded.

### Git process isolation

Git import runs with sanitized configuration and environment. Tokens never
appear in:

- submitted or persisted source URLs;
- OS command arguments;
- Git remotes or configuration;
- environment values;
- captured stdout or stderr;
- logs, telemetry metadata, audit metadata, or reports; or
- persistent credential-helper files.

The credential broker exists only for the bounded child-process lifetime. Its
endpoint and staging permissions prevent access by other local users. Cleanup
runs after normal completion, cancellation, timeout, and worker crash.

### Authorization

Discovery does not authorize a local destination mutation. Start and
publication both recheck the active local actor:

- personal imports require the active personal owner;
- organization imports require local organization ownership; and
- replacement requires repository-admin permission.

Private destination existence continues to use existing masking outside the
authenticated import workflow. One user cannot view another user's sources,
credentials, run progress, conflicts, or reports.

Before imports are enabled, authenticated namespace pages must use the existing
authorized repository-view boundary rather than listing every repository owned
by a namespace. Imported private repository metadata must remain hidden from
unpermitted users on namespace pages as well as repository routes and APIs.

### Redaction

Phoenix parameter filtering and `Fornacast.Audit` redaction cover `pat`,
`github_pat`, `access_token`, `authorization`, credential envelopes, and future
credential-like keys. Import errors are classified before logging. Raw Git
output, raw HTTP bodies, absolute storage paths, decrypted credentials, and
inspected internal terms are never user-visible.

## Error Model

Stable expected failures include:

- invalid or expired credential;
- insufficient GitHub repository or organization access;
- GitHub primary or secondary rate limit;
- source repository removed, renamed, or changed during import;
- destination authorization or conflict changed;
- unsupported source object;
- source validation failure;
- Git timeout, cancellation, or corrupt mirror;
- configured repository-size or storage-capacity limit;
- local storage, database, write-fence, or recovery unavailability; and
- publication conflict or lost operation lease.

The UI presents a sanitized explanation and recovery action. Diagnostic details
are retained only in bounded, redacted form. Unexpected errors crash the worker
and are reconciled from durable state.

Rate-limited items persist the earliest permitted retry time from GitHub headers
and expose that pause on the progress page. They do not busy-retry.

## Web Experience

All import and GitHub-account routes use the authenticated browser pipeline.
Mutation routes use CSRF protection and non-GET verbs.

### GitHub settings

`/settings/github` lists linked GitHub identities with:

- `Github:<login>` identity and verified profile link;
- saved-credential status and last verification time;
- reverify and replace-PAT actions;
- delete-saved-PAT action without unlinking; and
- unlink action without deleting historical external identity rows.

The raw PAT is never rendered after form submission.

### Repository import

The existing `/repos/import` route becomes the repository import entrypoint:

1. enter or select a GitHub repository;
2. choose a saved credential or one-time PAT;
3. choose destination owner, slug, visibility, and supported settings;
4. resolve any conflict;
5. review the exact migration plan; and
6. start and follow the durable run.

### Organization import

`/organizations/import` provides:

1. GitHub credential and organization selection;
2. repository discovery;
3. new or existing local organization selection;
4. an all-selected repository table with per-row exclusions;
5. per-repository conflict actions and apply-to-similar controls;
6. a final plan review; and
7. durable progress and report navigation.

### Progress and reports

`/imports/:id` shows overall state and every repository item's phase, counts,
rate-limit pause, sanitized warnings/failures, and published link. Applicable
controls include cancel, create-successor-retry, and return to conflict
resolution. Retry links the new run back to the immutable predecessor report and
only includes unpublished retryable items.

Pages are server-rendered HEEx using PhoenixDuskmoon components. A small
authenticated, owner-scoped status endpoint supports progressive polling.
Without JavaScript, manual refresh and ordinary forms preserve complete
functionality. This feature does not introduce a LiveView-only subsystem.

The terminal report accounts for every selected repository and every fetched
supported or unsupported source object. It distinguishes imported, skipped,
warning, failed, canceled, and not-selected outcomes.

Excluded feature categories are always named, but the importer does not spend
GitHub rate-limit budget enumerating resources solely to count unsupported data.
Counts are included only when discovery or a supported-resource response already
provides them.

## Audit and Observability

Audited actions include:

- GitHub account linked or unlinked;
- saved credential replaced or deleted;
- import discovered and started;
- conflict decisions frozen;
- import cancellation requested;
- repository published or replaced;
- import completed, completed with warnings, canceled, or failed; and
- tombstoned storage reclaimed.

Audit metadata contains local actor and target IDs, GitHub numeric resource IDs,
counts, classified outcomes, and request metadata. It never contains PATs,
authorization headers, raw remote URLs with user information, response bodies,
or storage paths.

Telemetry covers phase duration, REST request outcome, rate-limit pauses, bytes
staged, publication outcome, retries, and cleanup. Labels use bounded phase and
error atoms rather than repository names, usernames, URLs, or exception text.

## Verification

### Domain and persistence tests

Cover:

- stable-ID identity matching and mutable login refresh;
- multiple GitHub identities per local user and one local user per identity;
- `Github:ghost` attribution for deleted source actors;
- attribution linking/unlinking without membership or access changes;
- credential encryption, key rotation, wrong-key failure, replacement, and
  terminal one-time cleanup;
- lifecycle visibility and repository-query exclusion;
- source-ID idempotency and transactional page checkpoints;
- exact issue/pull numbering and timestamps;
- label, assignee, comment, and representable pull-request mapping;
- unsupported-object report accounting; and
- number-sequence continuation after the highest import.

### Git and HTTP adapter tests

Use a controllable fake GitHub REST server and local bare Git fixtures to cover:

- pagination and rate-limit pauses;
- expired, forbidden, missing, malformed, oversized, and drifting sources;
- public and authenticated bare mirrors;
- timeout, cancellation, corrupt repositories, and disk limits;
- prohibited protocols, redirects, configuration, hooks, and submodule
  execution; and
- proof that tokens do not appear in arguments, configuration, output, logs,
  reports, or filesystem remnants.

Normal tests require no developer GitHub PAT. An opt-in live smoke test may use
a public repository and must not persist a credential.

### Recovery and publication tests

Inject crashes after every durable phase and cover:

- lease loss and worker restart;
- replayed REST pages without duplicates;
- cancellation during Git and metadata phases;
- no cancellation inside publication;
- conflict-target drift returning to resolution;
- new activation and confirmed replacement;
- replacement publishing a new repository ID while preserving the owner/slug
  URL and local collaborators;
- stale queued writers failing after replacement;
- old readers finishing against retained storage;
- failure before publication leaving the live repository unchanged;
- startup reconciliation; and
- delayed cleanup after the grace period.

### Web tests

Cover authentication, run ownership, CSRF, saved and one-time credentials,
identity settings, repository and organization discovery, selection defaults,
reserved namespace validation, private namespace-list masking, per-item and bulk
conflict choices, typed replacement confirmation, progress, cancellation,
successor retry, reports, and no-JavaScript fallback behavior.

### Existing regression surface

Focused tests for touched apps run against both Turso and PostgreSQL. Existing
repository authorization masking, Git clone/fetch/push, write policy, repository
browsing, Issues, Pull Requests, GraphQL, and GitHub-compatible REST contracts
must remain green. This web-only feature does not change the pinned public REST
route manifest or OpenAPI artifacts.

## Acceptance Criteria

The feature is complete when all of the following are proven:

- a user can link multiple GitHub accounts and manage saved credentials without
  credential disclosure;
- a repository can be imported with a saved or one-time PAT;
- an organization can be discovered, filtered, conflict-resolved, and imported
  with mixed skip, rename, replace, success, and failure outcomes;
- Git branches, tags, supported repository metadata, issues, comments, labels,
  assignees, and representable pull requests retain source identity, numbering,
  timestamps, and attribution;
- deleted GitHub actors remain attributable as `Github:ghost` without creating
  login accounts;
- unsupported objects, including releases, are explicitly reported;
- a failed pre-publication import exposes no partial repository and leaves an
  existing destination unchanged;
- replacement activates a new hidden repository atomically while preserving
  local authorization and retaining old storage for safe reclamation;
- restart during Git transfer or metadata pagination automatically recovers;
- imported private repository metadata remains masked on namespace pages;
- cancellation and successor retry behave according to durable checkpoints
  without mutating predecessor reports;
- one-time credential material is absent after every terminal outcome;
- no PAT appears in logs, audits, process arguments, Git configuration,
  reports, or generated files; and
- all scoped Turso/PostgreSQL and existing regression tests pass.

## Delivery Decomposition

Implementation should remain one approved product design but proceed through
four independently verifiable milestones:

1. GitHub identities, encrypted credentials, import persistence, GitHub client,
   and settings/discovery UI;
2. supervised Git mirror, hidden repository lifecycle, repository publication,
   replacement, and repository-import UI;
3. issues, comments, labels, assignees, pull requests, external attribution,
   provenance, and checkpointed metadata import; and
4. organization selection/orchestration, recovery hardening, reports,
   cancellation/retry, cross-adapter verification, and end-to-end acceptance.

No milestone is complete merely because its worker starts or its database rows
exist. Each milestone must prove its visible or recoverable outcome through the
scoped acceptance tests above.

## GitHub References

- [Get the authenticated user](https://docs.github.com/en/rest/users/users)
- [Token expiration and revocation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation)
- [About remote repositories](https://docs.github.com/en/get-started/git-basics/about-remote-repositories)
- [Using pagination in the REST API](https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api)
- [REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- [REST API best practices](https://docs.github.com/en/enterprise-cloud@latest/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
- [GraphQL rate and query limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)
- [Organization migration API](https://docs.github.com/en/rest/migrations/orgs)
