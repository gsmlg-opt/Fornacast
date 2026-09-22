# Organization Settings Design

**Status:** Implemented and verified.
**Baseline:** `3fdd9bb` (`v0.4.0`), inspected 2026-09-22.
**Requested outcome:** An organization settings page like GitHub's.
**Confirmed scope:** General and existing GitHub integration. The user explicitly excludes team, membership, and authorization management.

## 1. Product direction

Use a visible organization Settings entry, persistent section navigation, compact
forms, and clear save/error feedback. Render these with Fornacast's existing
Phoenix/DuskMoon components, typography, and sunshine/moonlight themes.

The recommended approach is to extend the existing server-rendered settings
pages with one shared HEEx layout. A single long page would mix profile editing
with the much larger GitHub integration. A new LiveView application would add
lifecycle and routing changes without a requirement for real-time interactions.
The shared layout gives each section its own URL and keeps the current controllers.

GitHub references, checked 2026-09-22:

- [Accessing organization settings](https://docs.github.com/en/organizations/collaborating-with-groups-in-organizations/accessing-your-organizations-settings): Settings entry under the organization name and role-dependent access.
- [Customizing an organization profile](https://docs.github.com/en/organizations/collaborating-with-groups-in-organizations/customizing-your-organizations-profile): profile administration. GitHub also supports avatars and profile READMEs; these are outside this scope.

GitHub is the reference for navigation and interaction. The result retains
Fornacast's visual theme and exposes its supported fields and integrations.

## 2. Current implementation

- `GET /organizations/:organization/settings` renders one GitHub sync card and
  depends on `ForgeImports.OrganizationSync.get_settings/2` to load the page.
- The organization namespace page (`/:owner`) has no Settings entry.
- `ForgeAccounts.update_organization/4` already validates and audits display name
  and description changes. The REST API exposes this operation.
- GitHub settings, installation, operational controls, and conflicts already exist.
- Canonical organization authorization already allows active owners and active
  site admins. Reuse it without adding permission configuration or new roles.

## 3. Navigation and layout

Add a Settings entry beside the organization identity on `/:owner`, visible to
actors allowed by the existing manageable-organization check. Personal namespace
pages retain their current navigation and repository visibility behavior.

Every organization settings page shares:

- Organization display name, `@slug`, and a link back to its repository page.
- A left navigation column (approximately 14rem) and flexible content column.
- **General** and **GitHub integration**, with `aria-current="page"` for the active section.
- Compact stacked navigation above content below the existing 760px breakpoint.
- Existing DuskMoon inputs, textarea, links, buttons, and alerts. Use semantic
  theme tokens, existing typography, and visible keyboard focus.
- One primary save action per form section, field-level validation, and accessible
  success/error feedback. Keep submitted values after validation errors.

Illustrative layout:

```text
Acme Engineering  @acme                         Back to organization
Organization settings

General                 General
GitHub integration      Display name   [Acme Engineering          ]
                        Description    [                           ]
                        Organization URL: /acme (read-only)
                        [Save changes]
```

Do not render People, Teams, Permissions, or other inactive navigation entries.

## 4. General

- Canonical page: `GET /organizations/:organization/settings`.
- Save: `PATCH /organizations/:organization/settings`.
- Editable fields: display name and description. Show slug and namespace URL as
  read-only information, with a usable link back to the organization.
- Reuse `ForgeAccounts.update_organization/4` and the current profile rules:
  display name up to 120 characters, description up to 500, trimming, NUL
  validation, and existing null behavior. Preserve the REST API contract.
- Select only permitted fields. Reject malformed form payloads; do not forward
  username, state, email, credentials, account kind, or role changes.
- Save success redirects to General and shows an accessible success alert.
  Validation returns 422 with field messages and submitted values. Do not render
  inspected changeset internals.
- No sync-facade call is required. A missing installation or provider outage
  cannot prevent profile viewing or editing.

## 5. GitHub integration

Keep all existing URLs, installation/callback behavior, permissions, sync actions,
and conflict operations. Place the existing settings and conflict content inside
the shared layout; keep GitHub integration active on both pages.

The GitHub page already provides connection and sync status. Remove the old
General page's dependency on that status; the navigation itself never queries
GitHub. Preserve conflict back links and all operation form targets.

An authorized integration error page should retain the shared navigation when
its organization has already been safely resolved. Masked 404s and invalid
callbacks must not gain organization details merely to populate a layout.

## 6. Architecture and existing security

Add one `FornacastWeb.OrganizationSettingsComponents` module with a HEEx layout
component. It accepts organization, active section, and an inner slot; it performs
no database queries or provider calls. Reuse existing responsive settings CSS.

Controllers remain thin:

1. Resolve the organization through the existing canonical manageable-organization API.
2. For General saves, pass the selected attributes and
   `FornacastWeb.RequestMetadata.from_conn/1` to `ForgeAccounts.update_organization/4`.
3. Render or redirect using the existing domain error contract.

The existing owner/site-admin checks remain enforced on every request. This
feature adds no role editor, membership mutations, policy settings, or new access
model. Unauthorized/missing organizations retain masked 404s; anonymous requests
retain login redirects. Existing CSRF protection and private/no-store headers
apply to both GET and PATCH, including failures and redirects.

Profile writes retain their existing atomic audit operation. No domain mutation
API, schema migration, REST endpoint, provider behavior, or dependency is added.

## 7. Explicit exclusions

Exclude teams, membership administration, invitations, permission/authorization
management, custom roles, default repository permissions, and SSO/2FA policies.
Also exclude avatar upload, new website/location fields, billing, secrets,
Actions, profile README customization, rename, transfer, and deletion.
Do not show nonfunctional controls for these features.

## 8. Acceptance criteria

- [x] Existing authorized actors can find Settings from an organization page;
  unauthorized actors and personal namespace visitors receive no org settings entry.
- [x] General, GitHub settings, and conflict pages share organization identity and
  consistent navigation; no People, Teams, or Permissions controls exist.
- [x] General edits display name/description, preserves immutable fields, and
  displays the organization slug/URL as read-only information.
- [x] Valid saves persist, redirect, and show success; invalid fields show useful
  errors and preserve input. User content is safely escaped.
- [x] General works with GitHub disabled, disconnected, or unavailable and makes
  no call to the organization-sync facade.
- [x] Existing authorization, CSRF, private/no-store, and profile audit behavior
  remain covered by scoped tests; no membership/permission behavior changes.
- [x] Existing GitHub install/callback/operation/conflict flows and both REST
  organization-profile versions still pass their focused regression tests.
- [x] Desktop/mobile, both themes, labels, keyboard navigation, error focus, and
  absence of horizontal overflow pass browser verification.
- [x] Only scoped tests run; any out-of-scope failure is reported without repair.

## 9. Delivery boundary

Implementation is complete when this checklist and the companion plan's scoped
checks pass. Stop there. Commit, push, release, deployment, and follow-up features
require their own authorization. After implementation, record the feature in
agent-note with `project: fornacast` under the repository's note workflow.
