# User Appearance settings

## Goal

Move the theme switcher from the appbar to User Settings → Appearance. Persist
the choice per user, load it from that account when its shared user process starts, and use `auto`
for anonymous visitors.

## Current behavior

`FornacastWeb.HTML` renders a theme menu in both authenticated and anonymous
appbars, including repository pages. `assets/js/app.js` reads and writes the
browser-wide `fornacast-theme` localStorage key. User Settings has Profile,
Applications, SSH Keys, and GitHub sections. There is no existing user
preferences store or account appearance field.

## Options and decision

1. Add a validated `users.theme_preference` field. This is the smallest durable account
   setting for the single preference requested and is the recommended approach.
2. Add a generic preferences map or separate preferences table. This provides
   room for future settings but introduces storage structure beyond this task.
3. Keep browser storage with user-specific keys. This does not provide the
   requested account persistence across browsers, so it is unsuitable.

## User interface

- Add Appearance after Profile in the existing User Settings sidebar.
- `GET /settings/appearance` shows the persisted selection using DuskMoon form
  controls, with Auto, Sunshine, and Moonlight options and a Save button.
- Auto follows the operating system's light/dark preference. Sunshine is light;
  Moonlight is dark.
- `PATCH /settings/appearance` saves the current authenticated user's choice,
  then redirects back to Appearance with confirmation. Invalid values render
  an error without changing the persisted selection.
- Remove theme controls from every authenticated and anonymous appbar.

## Storage and authorization

- Add `users.theme_preference` as a non-null string with default `auto`. Existing users
  therefore start in auto mode.
- Add a changeset restricted to theme and validating `auto`, `sunshine`, and
  `moonlight`.
- Expose a ForgeAccounts context API that reloads the active actor and updates
  only that account. Ignore unrelated submitted fields; do not accept a target
  user ID from the form.
- Keep both appearance routes within the existing authenticated browser
  pipeline with CSRF protection.

## Session configuration state

Use the published `phoenix_session_process ~> 1.0.1` package in the web application
supervision tree for both process types:

- One user process per user ID holds shared account configuration, including
  Appearance. Its stable process key is derived from the user ID.
- Each login session has its own session process holding only its owning user
  ID. Multiple sessions reference the same user process and never copy theme
  into session state. The signed cookie holds an opaque session identifier.

Load appearance from PostgreSQL only when the user process is missing after
expiry, crash, or restart. Login may seed a missing user process from the
already-authenticated user, but must preserve an existing shared preference.
Every authenticated request touches both processes; user state can expire after
inactivity. Recreating a missing session rotates its opaque identifier and
preserves a surviving user process.

Serialize shared user initialization, reads, saves, and explicit retirement
under one per-user lock. Database reads and saves run in the request process.
After a successful database save, update shared state synchronously so all of
that user's sessions see the saved preference on subsequent requests. Logout
terminates only the current session process and leaves user state and sibling
sessions intact. Namespace user and session keys separately and check ownership
before using or terminating a session.

Keep the current request's identity and authorization checks separate from
configuration caching. The current-user query excludes appearance fields;
normal requests read appearance only from the shared user process.

## Theme loading

- Both standard and repository page renderers emit `data-theme-preference`
  from the current user's shared configuration, or `auto` when anonymous.
- JavaScript resolves auto to sunshine or moonlight through
  `prefers-color-scheme` and continues listening for operating system changes
  while auto is selected.
- Remove the localStorage theme reader/writer. Previous browser choices must
  not override the signed-in account or anonymous auto behavior.
- Saving applies the preference after the redirect; unsaved selections do not
  change the account's theme.

## Verification

- Scoped PostgreSQL account tests cover the default, all valid values, invalid
  and missing values, account isolation, and restricted update fields.
- Scoped web tests cover the Appearance navigation and selected choice,
  authenticated save, invalid submissions, anonymous access, and loading on
  both standard and repository pages.
- Update existing appbar assertions to verify theme controls are absent.
- Verify one user process shared by multiple distinct sessions, cross-session
  saves without repeated configuration SQL, account isolation, login rotation,
  session-only logout, user/session recovery, concurrent initialization/saves,
  and stable-user-key cleanup safety.
- Verify JavaScript against stale browser storage, auto light/dark resolution,
  operating system changes, and fixed themes.
- Run scoped tests on the devenv PostgreSQL Unix socket with `PGPORT=55432`,
  format checks, asset build, and `git diff --check`.

## Process cleanup and reconstruction

Hex phoenix_session_process 1.0.1 fixes upstream Bug
`gsmlg-dev/phoenix_session_process#58`: explicit termination now cancels cleanup
timers and removes activity tracking. Require at least this patch version;
manual ActivityTracker removal and the former workaround markers are removed.

For a stable user key, still synchronously call the package's
`Cleanup.cancel_session_cleanup/1` before retirement/replacement, under the
per-user lock. This waits for in-progress old cleanup callbacks and clears
stale tracking after a crash, even when no process remains. Ordinary termination
of a missing process returns not-found without clearing that tracking.

## Scope

Only account appearance storage, the settings page, theme loading, related
appbar removal, and scoped verification are included. No other appearance
preferences or unrelated settings changes are included. Implementation should
use an isolated worktree under this project's `.trees` directory and preserve
unrelated changes. No commit or push is requested.
