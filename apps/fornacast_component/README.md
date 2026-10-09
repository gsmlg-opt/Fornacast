# Fornacast Component

Application-owned Phoenix presentation components. DuskMoon supplies foundation
controls, icons, and theme tokens; this app owns Git repository presentation and
shared repository layouts.

The app has no supervisor, database, endpoint, router, or domain dependencies.
Consumers supply authorized presentation data, prepared URLs, and slots. Rendering
must not perform domain reads, authorization, configuration lookups, or Git I/O.

```elixir
use Phoenix.Component
use FornacastComponent
```

The facade imports `FornacastComponent.GitRepository` and
`FornacastComponent.RepositoryLayout`. Components use the `fc_` prefix:

- `fc_git_repository_header`: independent `owner_href` and `name_href` title links.
- `fc_git_repository_nav`: prepared navigation links, active states, and counts.
- `fc_git_file_tree`: linked files, folders, symlinks, and submodules.
- `fc_git_blob_viewer`: escaped text, raw links, and explicit display limits.
- `fc_git_commit_diff`: commit metadata and bounded unified diffs.
- `fc_git_clone_box`: clone URLs, setup commands, and clipboard controls.

Header URLs are supplied by the consumer. Repository-name links should use the
canonical repository root independently of the selected ref, file path, or page.
Omitted URL values preserve plain-text labels. The shared frame accepts a plain
presentation `view` and an inner content slot.

The private `fornacast-component` npm workspace exports clipboard behavior:

```javascript
import { installClipboardBehavior } from "fornacast-component/clipboard";

installClipboardBehavior();
```

Initialization is idempotent and uses delegated events for replaced content.
Controls use `data-fc-copy-*` attributes to avoid colliding with DuskMoon runtime
handlers. Successful and failed copies announce feedback; clipboard fallback
restores focus when the browser Clipboard API is unavailable.

Consumers must include this app's `lib` directory in Tailwind source scanning.
The app uses DuskMoon theme tokens and native HEEx; it adds no alternate UI kit.

Run component checks from this app directory using the project's devenv shell
with `mix test --no-start`. Tests need no domain database or SQL sandbox. Run
clipboard tests with `npm test --workspace fornacast-component` from the umbrella
root. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for source provenance
and the complete MIT notice.

The complete MIT notice is also included in `priv/THIRD_PARTY_NOTICES.md` so OTP releases and Docker artifacts retain it alongside the copied code. Keep both notice copies synchronized.
