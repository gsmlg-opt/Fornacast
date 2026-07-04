# Forgejo-Inspired DuskMoon UI Design

Date: 2026-07-05
Status: Proposed

## Context

Fornacast is a small self-hosted Git forge with a narrow first-release scope:
local users, SSH keys, private/public repositories, Git-over-SSH, basic smart
HTTP clone, and repository browsing. The Phoenix web app currently uses
controller-rendered HTML strings, with DuskMoon, Tailwind v4, and Bun already
wired into the asset pipeline.

The current UI pass should improve the full existing app surface without
changing product behavior or expanding feature scope.

## Reference Direction

Use Forgejo as the product reference for structure and expectations:

- repository-first navigation
- compact operational density
- familiar owner/repo headers
- local repository tabs
- readable tables for repositories, refs, commits, and keys
- clear clone and push instructions for empty repositories
- utility-first setup and login pages

This is not a pixel-for-pixel copy. The result should be a DuskMoon-native,
Forgejo-inspired operational forge.

## Design Direction

The chosen direction is **Workbench Forge**.

Fornacast should feel like a compact self-hosted Git workbench: restrained,
trustworthy, scan-friendly, and built for repeated use. The UI should avoid
marketing-page composition and decorative flourish. It should prioritize
repository operations, Git commands, and source browsing.

## Goals

- Apply a coherent DuskMoon shell across the full current web app.
- Improve dashboard, repository, source, commit/ref, SSH key, setup, and login
  pages.
- Make repository operations easier to scan and act on.
- Use DuskMoon design tokens consistently, including theme-compatible surface,
  text, border, and action colors.
- Preserve the existing controller routes and first-release behavior.
- Verify the refreshed UI in Chrome DevTools across desktop and mobile widths.

## Non-Goals

- No LiveView conversion.
- No route changes.
- No new repository features such as issues, pull requests, CI, packages, LFS,
  forks, or collaboration settings.
- No Forgejo API compatibility work.
- No authentication behavior changes.
- No hardcoded colors, Tailwind palette colors, or inline color styles.

## Shell

Authenticated pages use a compact application shell:

- `bg-surface text-on-surface` body base.
- Primary DuskMoon-style appbar as the brand anchor.
- Secondary navigation rail for core actions: Dashboard, New repository, SSH
  keys.
- Compact server/status block in the rail, using supporting text rather than a
  primary action.
- Main content on `surface`, with content panels using elevated surface tokens.
- One primary page action per visible section.

Unauthenticated pages use the same brand language without the rail:

- setup and login are focused utility pages.
- forms sit in contained surfaces with concise supporting copy.
- no hero layout, no marketing split panel.

## Page Model

### Dashboard

The dashboard centers the repository list.

- Header includes a short account/repository summary and one primary "New
  repository" action.
- Repository table uses compact rows with repository name, visibility, default
  branch, and last-push state if available.
- Empty state gives a direct path to create the first repository.

### Repository Overview

Repository pages use a Forgejo-like owner/repo header.

- Header includes `owner / repo`, visibility badge, default branch, and
  description.
- Local tabs: Code, Commits, Branches, Tags.
- Empty repository state shows clone URL and push instructions in monospace
  command blocks.
- Non-empty repository state shows README/content in a contained reading
  surface below the tabs.

### Source And File Views

Source browsing should feel dense and code-native.

- Path bar shows branch/ref and current path.
- Tree view uses a compact table/list with folder/file distinction.
- File view uses an elevated file panel with filename, size, raw link, and a
  scrollable monospace code block.
- Raw action stays secondary to browsing.

### Commits, Branches, Tags

These are compact data views.

- Commit hashes use monospace and short hash presentation.
- Branch and tag rows keep target hash visible but visually secondary.
- Tables use hover/zebra behavior if available through DuskMoon-compatible CSS.

### SSH Keys

SSH keys are a settings-style data page.

- Add-key form sits in a contained panel above or beside the key table,
  depending on viewport width.
- Existing keys use a dense table with title, fingerprint, and a destructive
  delete action.
- Delete is the only destructive action and must use the error/action pattern.

### Setup And Login

Setup and login are utility pages.

- Keep forms compact and obvious.
- Setup copy explains only the first-admin purpose.
- Login stays direct; no account creation affordance unless the existing app
  supports it.

## Component And Styling Strategy

Keep the current controller-rendered HTML approach, but extract small helper
functions where they reduce duplication or clarify intent.

Likely helper areas:

- page shell/appbar/rail
- section header
- repository tabs
- badges
- action links/buttons
- form panels
- table wrappers
- command/code blocks
- empty/error states

Use DuskMoon components directly only where they fit the existing rendering
model cleanly. Otherwise use DuskMoon token classes and component-compatible CSS
to keep the implementation narrow.

## Visual System

- Body: `bg-surface text-on-surface`.
- Appbar: primary.
- Authenticated rail: secondary with paired secondary content text.
- Cards/panels: `surface-container`, elevated sections as
  `surface-container-high`.
- Primary buttons: one per view or visible section.
- Secondary/ghost/outline styles for supporting actions.
- Semantic colors only for semantic states.
- Monospace treatment for clone URLs, shell commands, commit hashes, and code.
- Typography should be distinctive but practical. Avoid Inter, Roboto, Arial,
  and default system fonts as the conscious design choice.
- Motion is subtle: hover lift, focus clarity, and theme/background
  transitions. Respect reduced-motion preferences.

## Accessibility And Responsiveness

- Forms must keep explicit labels.
- Navigation and table links must have visible text.
- Buttons must not rely on color alone to communicate destructive behavior.
- Mobile layouts collapse the rail into a stacked/top navigation pattern or a
  compact horizontal action area.
- No horizontal overflow at common mobile widths.
- Long repo names, fingerprints, hashes, and file paths must wrap or scroll in
  controlled containers.

## Implementation Boundary

Allowed files:

- `apps/fornacast_web/lib/fornacast_web/html.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/*_controller.ex`
- `apps/fornacast_web/assets/css/app.css`
- `apps/fornacast_web/assets/js/app.js` only if needed for theme switching or
  DuskMoon hooks
- focused tests under `apps/fornacast_web/test`

Do not change data models, routes, auth behavior, Git transport behavior, or
database behavior for this UI pass.

## Verification Plan

Run local checks:

- `mix format`
- `mix test apps/fornacast_web/test`
- `MIX_ENV=prod FORNACAST_DATABASE_ADAPTER=turso mix assets.deploy`

Use Chrome DevTools for visual verification:

- setup page
- login page
- dashboard
- new repository form
- repository overview
- empty repository state
- source tree
- file view
- commits/branches/tags tables
- SSH keys page
- desktop and mobile widths

Check for:

- console errors
- failed asset requests
- horizontal overflow
- text overlap
- broken focus/hover states
- unreadable long paths, hashes, or fingerprints

## Risks

- The current raw HTML string approach can become hard to maintain if large
  templates are added directly to controllers. Mitigation: extract small HTML
  helpers for repeated UI patterns.
- DuskMoon component helpers may be awkward inside string-rendered controller
  views. Mitigation: use token-compatible markup where component helpers do not
  fit cleanly.
- The app could drift toward a partial Forgejo clone. Mitigation: preserve
  Fornacast's first-release scope and only borrow proven forge UI patterns.
