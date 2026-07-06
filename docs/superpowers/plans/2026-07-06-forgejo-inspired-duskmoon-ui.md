# Forgejo-Inspired DuskMoon UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the full current Fornacast web UI into a compact Forgejo-inspired DuskMoon workbench without changing routes, authentication, Git transport, persistence, or first-release product scope.

**Architecture:** Keep the existing controller-rendered HTML model and add a small shared HTML helper layer in `FornacastWeb.HTML` for the shell, panels, action links, badges, tables, command blocks, and repository chrome. Style those helpers through DuskMoon token-compatible CSS in the existing asset pipeline, then update each controller page in narrow groups. Verify with focused controller tests, production asset compilation, and Chrome DevTools screenshots across desktop and mobile.

**Tech Stack:** Phoenix controllers, Phoenix.ConnTest, DuskMoon Elements and Tailwind v4 assets, Bun asset pipeline, Chrome DevTools MCP visual checks.

---

## Source Findings

- The current UI is raw HTML assembled in Phoenix controllers and rendered through `FornacastWeb.HTML.page/3`.
- DuskMoon assets are already wired through `apps/fornacast_web/assets/css/app.css` and `apps/fornacast_web/assets/js/app.js`.
- The web test suite already covers login, setup, SSH key creation, repository creation, empty repository state, repository browsing, raw file download, refs, commits, and smart HTTP behavior.
- This refresh must remain inside the approved implementation boundary and must not add LiveView, new routes, new forge features, or data-model changes.

## File Structure

- Modify `apps/fornacast_web/lib/fornacast_web/html.ex`: keep `page/3`, `escape/1`, and `csrf_input/0`; add reusable raw-HTML helpers for the authenticated shell, unauthenticated utility shell, action links, badges, form panels, empty/error states, command/code blocks, data tables, and repository chrome.
- Modify `apps/fornacast_web/assets/css/app.css`: replace hardcoded color styling with DuskMoon token classes and component-level CSS for the app shell, rail, panels, tables, forms, tabs, command blocks, code blocks, and responsive/mobile behavior.
- Modify `apps/fornacast_web/assets/js/app.js`: keep DuskMoon element registrations and add a small persisted theme toggle if the shell includes `data-theme-toggle`.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/session_controller.ex`: refresh login and invalid-login views using shared utility-form helpers.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex`: refresh setup, already-initialized, and validation-error views using shared utility-form helpers.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/dashboard_controller.ex`: refresh dashboard header, repository table, repository badges, and empty repository prompt.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex`: refresh SSH-key settings form, key table, empty state, and delete action.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`: refresh new-repository form, repository header/tabs, empty repository instructions, overview README panel, source tree, file panel, refs, commits, and commit detail views.
- Modify `apps/fornacast_web/test/fornacast_web_test.exs`: add UI contract assertions to existing browser-flow tests.
- Modify `apps/fornacast_web/test/setup_wizard_test.exs`: add setup utility-page UI contract assertions.
- Do not modify router, plugs, schemas, contexts, migrations, Git transport, or database configuration.

## Task 1: Add UI Contract Tests

**Files:**
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`
- Modify: `apps/fornacast_web/test/setup_wizard_test.exs`

- [ ] **Step 1: Extend the setup page contract**

In `apps/fornacast_web/test/setup_wizard_test.exs`, update `test "GET /setup renders the admin form"` so it asserts the utility shell and form panel that the implementation will provide:

```elixir
test "GET /setup renders the admin form" do
  conn = get(build_conn(), "/setup")
  body = html_response(conn, 200)

  assert body =~ ~s(class="auth-shell")
  assert body =~ ~s(class="form-panel")
  assert body =~ "First administrator"
  assert body =~ "Create the first administrator"
  assert body =~ ~s(name="admin[username]")
end
```

- [ ] **Step 2: Extend the login and empty repository contract**

In `apps/fornacast_web/test/fornacast_web_test.exs`, inside `test "login, SSH key, repository creation, empty state, and private access policy"`, replace the login-form assertion with these assertions:

```elixir
login_form = get(build_conn(), "/login")
login_body = html_response(login_form, 200)
assert login_body =~ ~s(class="auth-shell")
assert login_body =~ ~s(class="form-panel")
assert login_body =~ "Sign in"
assert login_body =~ ~s(name="session[username]")
```

After the `empty = ... |> get("/alice/empty")` call, replace the existing empty-state assertions with:

```elixir
empty_body = html_response(empty, 200)
assert empty_body =~ ~s(class="repo-header")
assert empty_body =~ "alice / empty"
assert empty_body =~ ~s(class="repo-tabs")
assert empty_body =~ ~s(class="empty-state")
assert empty_body =~ ~s(class="command-block")
assert empty_body =~ "git push -u origin main"
assert empty_body =~ "ssh://alice@"
```

- [ ] **Step 3: Extend the repository browser contract**

In `apps/fornacast_web/test/fornacast_web_test.exs`, inside `test "repository browser renders README, source, raw file, and commit metadata"`, replace:

```elixir
overview = get(conn, "/alice/demo")
assert html_response(overview, 200) =~ "<h1>Demo</h1>"
refute html_response(overview, 200) =~ "<script>"
```

with:

```elixir
overview = get(conn, "/alice/demo")
overview_body = html_response(overview, 200)
assert overview_body =~ ~s(class="repo-header")
assert overview_body =~ "alice / demo"
assert overview_body =~ ~s(class="repo-tabs")
assert overview_body =~ ~s(class="readme-panel")
refute overview_body =~ "<script>"
```

Then add source/file UI assertions next to the existing source and file checks:

```elixir
source = get(conn, "/alice/demo/src/main/docs")
source_body = html_response(source, 200)
assert source_body =~ ~s(class="path-bar")
assert source_body =~ ~s(class="data-table source-table")
assert source_body =~ "guide.txt"

file = get(conn, "/alice/demo/src/main/docs/guide.txt")
file_body = html_response(file, 200)
assert file_body =~ ~s(class="file-panel")
assert file_body =~ ~s(class="code-block")
assert file_body =~ "hello"
```

- [ ] **Step 4: Add dashboard and SSH-key surface checks**

In `apps/fornacast_web/test/fornacast_web_test.exs`, inside `test "login, SSH key, repository creation, empty state, and private access policy"`, after the successful login redirect and before posting the SSH key, add:

```elixir
dashboard =
  login
  |> recycle()
  |> get("/")

dashboard_body = html_response(dashboard, 200)
assert dashboard_body =~ ~s(class="app-shell")
assert dashboard_body =~ ~s(class="app-rail")
assert dashboard_body =~ ~s(class="section-header")
assert dashboard_body =~ "Repositories"
```

After the SSH key creation redirect, add:

```elixir
ssh_keys =
  key
  |> recycle()
  |> get("/ssh-keys")

ssh_keys_body = html_response(ssh_keys, 200)
assert ssh_keys_body =~ ~s(class="settings-grid")
assert ssh_keys_body =~ ~s(class="form-panel")
assert ssh_keys_body =~ ~s(class="data-table key-table")
assert ssh_keys_body =~ "SHA256:"
```

- [ ] **Step 5: Run the focused tests and verify they fail for missing UI classes**

Run:

```bash
mix test apps/fornacast_web/test/setup_wizard_test.exs apps/fornacast_web/test/fornacast_web_test.exs --trace
```

Expected: tests fail with assertions for missing strings such as `class="auth-shell"`, `class="repo-header"`, `class="app-shell"`, `class="path-bar"`, or `class="settings-grid"`.

- [ ] **Step 6: Commit the failing UI contract tests**

Run:

```bash
git add apps/fornacast_web/test/setup_wizard_test.exs apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "test(ui): describe Forgejo-inspired web shell"
```

Expected: commit succeeds with only test-file changes.

## Task 2: Build Shared HTML Primitives

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/html.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`
- Test: `apps/fornacast_web/test/setup_wizard_test.exs`

- [ ] **Step 1: Replace `page/3` with an authenticated/utility shell dispatcher**

In `apps/fornacast_web/lib/fornacast_web/html.ex`, keep the existing imports and public helper names, then replace the body of `page/3` with this shape:

```elixir
def page(conn, title, body) do
  current_user = conn.assigns[:current_user]
  css_path = FornacastWeb.Endpoint.static_path("/assets/app.css")
  js_path = FornacastWeb.Endpoint.static_path("/assets/app.js")
  content = if current_user, do: app_shell(conn, current_user, title, body), else: auth_shell(title, body)

  html = """
  <!doctype html>
  <html lang="en" data-theme="sunshine">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="csrf-token" content="#{Plug.CSRFProtection.get_csrf_token()}">
    <title>#{escape(title)} - Fornacast</title>
    <link rel="stylesheet" href="#{escape(css_path)}">
    <script defer type="text/javascript" src="#{escape(js_path)}"></script>
  </head>
  <body class="app-body bg-surface text-on-surface">
    #{content}
  </body>
  </html>
  """

  conn
  |> put_resp_content_type("text/html")
  |> send_resp(conn.status || 200, html)
end
```

- [ ] **Step 2: Add shell helpers**

In the same module, add private helpers below `csrf_input/0`:

```elixir
defp auth_shell(title, body) do
  """
  <div class="auth-shell">
    <header class="auth-brand">
      <a class="brand-mark" href="/">Fornacast</a>
      <button class="theme-toggle" type="button" data-theme-toggle aria-label="Toggle theme">Theme</button>
    </header>
    <main class="auth-main" aria-labelledby="page-title">
      <p class="eyebrow">Self-hosted Git forge</p>
      <h1 id="page-title">#{escape(title)}</h1>
      #{body}
    </main>
  </div>
  """
end

defp app_shell(conn, current_user, title, body) do
  active = active_section(conn.request_path)

  """
  <div class="app-shell">
    #{appbar(current_user)}
    <div class="app-frame">
      #{rail(active, current_user)}
      <main class="app-main" aria-labelledby="page-title">
        <h1 id="page-title" class="sr-only">#{escape(title)}</h1>
        #{body}
      </main>
    </div>
  </div>
  """
end

defp appbar(current_user) do
  """
  <header class="appbar appbar-primary appbar-sticky">
    <a class="brand-mark" href="/">Fornacast</a>
    <div class="appbar-actions">
      <span class="user-chip">#{escape(current_user.username)}</span>
      <button class="theme-toggle" type="button" data-theme-toggle aria-label="Toggle theme">Theme</button>
      <form action="/logout" method="post" class="inline">
        #{csrf_input()}
        <input type="hidden" name="_method" value="delete">
        <button class="btn btn-ghost" type="submit">Logout</button>
      </form>
    </div>
  </header>
  """
end

defp rail(active, _current_user) do
  """
  <aside class="app-rail bg-secondary text-secondary-content" aria-label="Main navigation">
    <nav class="rail-nav">
      #{rail_link("/", "Dashboard", active == :dashboard)}
      #{rail_link("/repos/new", "New repository", active == :new_repository)}
      #{rail_link("/ssh-keys", "SSH keys", active == :ssh_keys)}
    </nav>
    <div class="rail-status">
      <strong>Local instance</strong>
      <span>Git over SSH and smart HTTP</span>
    </div>
  </aside>
  """
end

defp rail_link(href, label, active?) do
  active_class = if active?, do: " is-active", else: ""
  ~s(<a class="rail-link#{active_class}" href="#{href}">#{escape(label)}</a>)
end

defp active_section("/"), do: :dashboard
defp active_section("/repos/new"), do: :new_repository
defp active_section("/ssh-keys"), do: :ssh_keys
defp active_section(_path), do: :repository
```

- [ ] **Step 3: Add public component helpers**

Add these public helpers in `FornacastWeb.HTML`:

```elixir
def section_header(title, subtitle, action_html \\ "") do
  """
  <section class="section-header">
    <div>
      <p class="eyebrow">Fornacast</p>
      <h2>#{escape(title)}</h2>
      <p class="muted">#{escape(subtitle)}</p>
    </div>
    <div class="section-actions">#{action_html}</div>
  </section>
  """
end

def primary_link(href, label), do: ~s(<a class="btn btn-primary" href="#{escape(href)}">#{escape(label)}</a>)

def ghost_link(href, label), do: ~s(<a class="btn btn-ghost" href="#{escape(href)}">#{escape(label)}</a>)

def badge(label, tone \\ "neutral"), do: ~s(<span class="badge badge-#{escape(tone)}">#{escape(label)}</span>)

def form_panel(title, description, form_html) do
  """
  <section class="form-panel">
    <div class="panel-heading">
      <h2>#{escape(title)}</h2>
      <p class="muted">#{escape(description)}</p>
    </div>
    #{form_html}
  </section>
  """
end

def empty_state(title, description, action_html \\ "") do
  """
  <section class="empty-state">
    <h2>#{escape(title)}</h2>
    <p class="muted">#{escape(description)}</p>
    #{action_html}
  </section>
  """
end

def error_panel(message), do: ~s(<section class="error-panel" role="alert">#{escape(message)}</section>)

def command_block(commands), do: ~s(<pre class="command-block"><code>#{escape(commands)}</code></pre>)

def code_block(content), do: ~s(<pre class="code-block"><code>#{escape(content)}</code></pre>)
```

- [ ] **Step 4: Run the focused tests**

Run:

```bash
mix test apps/fornacast_web/test/setup_wizard_test.exs apps/fornacast_web/test/fornacast_web_test.exs --trace
```

Expected: setup/login/dashboard shell assertions may pass, while page-specific assertions still fail until controller bodies are refreshed.

- [ ] **Step 5: Commit the shared helper layer**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/html.ex
git commit -m "feat(ui): add DuskMoon workbench shell helpers"
```

Expected: commit succeeds with only `html.ex`.

## Task 3: Replace CSS and Add Theme Toggle

**Files:**
- Modify: `apps/fornacast_web/assets/css/app.css`
- Modify: `apps/fornacast_web/assets/js/app.js`

- [ ] **Step 1: Replace the current CSS with DuskMoon-token styling**

Replace the hardcoded CSS in `apps/fornacast_web/assets/css/app.css` after the existing imports with this token-compatible structure:

```css
@layer base {
  html {
    color-scheme: light dark;
  }

  body.app-body {
    @apply bg-surface text-on-surface;
    font-family: "Aptos", "Segoe UI", sans-serif;
    line-height: 1.5;
    margin: 0;
    min-height: 100vh;
  }

  a {
    color: inherit;
    text-decoration: none;
  }

  a:hover {
    text-decoration: underline;
  }

  input,
  textarea,
  select {
    @apply bg-surface-container text-on-surface border-outline;
    border-width: 1px;
    border-radius: 6px;
    box-sizing: border-box;
    display: block;
    margin: 6px 0 14px;
    max-width: 100%;
    padding: 10px 12px;
    width: 100%;
  }

  label {
    display: block;
    font-weight: 650;
  }

  table {
    border-collapse: collapse;
    width: 100%;
  }

  th,
  td {
    @apply border-outline-variant;
    border-bottom-width: 1px;
    padding: 10px 12px;
    text-align: left;
    vertical-align: top;
  }

  code,
  pre {
    font-family: "JetBrains Mono", "SFMono-Regular", Consolas, monospace;
  }
}
```

- [ ] **Step 2: Add component CSS for shell, panels, tables, and repository views**

Continue in `apps/fornacast_web/assets/css/app.css` with this component layer:

```css
@layer components {
  .inline {
    display: inline;
  }

  .sr-only {
    height: 1px;
    margin: -1px;
    overflow: hidden;
    position: absolute;
    width: 1px;
  }

  .appbar {
    @apply bg-primary text-primary-content border-outline-variant;
    align-items: center;
    border-bottom-width: 1px;
    display: flex;
    gap: 16px;
    justify-content: space-between;
    min-height: 58px;
    padding: 0 24px;
  }

  .appbar-sticky {
    position: sticky;
    top: 0;
    z-index: 20;
  }

  .brand-mark {
    font-size: 1.15rem;
    font-weight: 800;
  }

  .appbar-actions,
  .rail-nav,
  .section-actions,
  .repo-tabs {
    align-items: center;
    display: flex;
    gap: 10px;
  }

  .app-frame {
    display: grid;
    grid-template-columns: 236px minmax(0, 1fr);
    min-height: calc(100vh - 58px);
  }

  .app-rail {
    padding: 20px 16px;
  }

  .rail-nav {
    align-items: stretch;
    flex-direction: column;
  }

  .rail-link {
    border-radius: 6px;
    font-weight: 700;
    padding: 10px 12px;
  }

  .rail-link.is-active,
  .rail-link:hover {
    @apply bg-secondary-container text-on-secondary-container;
    text-decoration: none;
  }

  .rail-status {
    @apply border-outline-variant text-secondary-content;
    border-top-width: 1px;
    display: grid;
    gap: 4px;
    margin-top: 24px;
    padding-top: 16px;
  }

  .app-main {
    margin: 0 auto;
    max-width: 1120px;
    padding: 28px;
    width: 100%;
  }

  .auth-shell {
    display: grid;
    min-height: 100vh;
    grid-template-rows: auto 1fr;
  }

  .auth-brand {
    align-items: center;
    display: flex;
    justify-content: space-between;
    padding: 22px 28px;
  }

  .auth-main {
    margin: 0 auto;
    max-width: 520px;
    padding: 48px 20px;
    width: 100%;
  }

  .section-header,
  .repo-header,
  .content-panel,
  .form-panel,
  .empty-state,
  .readme-panel,
  .file-panel {
    @apply bg-surface-container text-on-surface border-outline-variant;
    border-width: 1px;
    border-radius: 8px;
    margin-bottom: 18px;
    padding: 18px;
  }

  .section-header,
  .repo-header {
    align-items: flex-start;
    display: flex;
    gap: 16px;
    justify-content: space-between;
  }

  .eyebrow,
  .muted {
    @apply text-on-surface-variant;
  }

  .eyebrow {
    font-size: 0.78rem;
    font-weight: 800;
    margin: 0 0 4px;
    text-transform: uppercase;
  }

  .btn,
  button {
    border: 0;
    border-radius: 6px;
    cursor: pointer;
    display: inline-flex;
    font-weight: 750;
    justify-content: center;
    padding: 9px 13px;
  }

  .btn-primary {
    @apply bg-primary text-primary-content;
  }

  .btn-ghost {
    @apply bg-surface-container-high text-on-surface;
  }

  .btn-danger {
    @apply bg-error text-error-content;
  }

  .btn-compact {
    padding: 6px 10px;
  }

  .theme-toggle,
  .user-chip,
  .badge {
    @apply bg-surface-container-high text-on-surface;
    border-radius: 999px;
    padding: 6px 10px;
  }

  .badge-public {
    @apply bg-tertiary text-tertiary-content;
  }

  .badge-private {
    @apply bg-secondary-container text-on-secondary-container;
  }

  .error-panel {
    @apply bg-error-container text-on-error-container border-error;
    border-width: 1px;
    border-radius: 8px;
    margin-bottom: 14px;
    padding: 12px 14px;
  }

  .data-table {
    @apply bg-surface-container border-outline-variant;
    border-width: 1px;
    border-radius: 8px;
    display: block;
    overflow-x: auto;
  }

  .path-bar,
  .repo-tabs {
    @apply bg-surface-container-high text-on-surface border-outline-variant;
    border-width: 1px;
    border-radius: 8px;
    margin-bottom: 12px;
    padding: 10px 12px;
  }

  .tab-link.is-active {
    font-weight: 800;
  }

  .command-block,
  .code-block {
    @apply bg-surface-container-highest text-on-surface;
    border-radius: 8px;
    overflow-x: auto;
    padding: 14px;
  }

  .settings-grid {
    display: grid;
    gap: 18px;
    grid-template-columns: minmax(260px, 380px) minmax(0, 1fr);
  }
}
```

- [ ] **Step 3: Add responsive CSS**

Append this responsive block:

```css
@media (max-width: 760px) {
  .app-frame,
  .settings-grid {
    grid-template-columns: 1fr;
  }

  .app-rail {
    padding: 12px;
  }

  .rail-nav {
    flex-direction: row;
    overflow-x: auto;
  }

  .section-header,
  .repo-header,
  .appbar,
  .appbar-actions {
    align-items: stretch;
    flex-direction: column;
  }

  .app-main {
    padding: 16px;
  }
}
```

- [ ] **Step 4: Add persisted theme toggle behavior**

In `apps/fornacast_web/assets/js/app.js`, keep both registration calls and append:

```javascript
const themeStorageKey = "fornacast-theme";
const savedTheme = window.localStorage.getItem(themeStorageKey);

if (savedTheme === "moonlight" || savedTheme === "sunshine") {
  document.documentElement.dataset.theme = savedTheme;
}

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-theme-toggle]");

  if (!button) {
    return;
  }

  const root = document.documentElement;
  const nextTheme = root.dataset.theme === "moonlight" ? "sunshine" : "moonlight";
  root.dataset.theme = nextTheme;
  window.localStorage.setItem(themeStorageKey, nextTheme);
});
```

- [ ] **Step 5: Compile production assets**

Run:

```bash
MIX_ENV=prod FORNACAST_DATABASE_ADAPTER=turso mix assets.deploy
```

Expected: Tailwind/DuskMoon asset build succeeds. If it fails because a DuskMoon token class does not exist, replace that class with a supported DuskMoon token already present in the asset build and rerun the command.

- [ ] **Step 6: Commit the asset styling**

Run:

```bash
git add apps/fornacast_web/assets/css/app.css apps/fornacast_web/assets/js/app.js
git commit -m "feat(ui): style DuskMoon workbench surfaces"
```

Expected: commit succeeds with only asset changes.

## Task 4: Refresh Login and Setup Pages

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/session_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex`
- Test: `apps/fornacast_web/test/setup_wizard_test.exs`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Add login form helpers in `SessionController`**

In `apps/fornacast_web/lib/fornacast_web/controllers/session_controller.ex`, replace the body passed by `new/2` with:

```elixir
form_panel("Sign in", "Use your local Fornacast account to access repositories.", login_form())
```

Then add:

```elixir
defp login_form do
  """
  <form action="/login" method="post">
    #{csrf_input()}
    <label>Username <input name="session[username]" autocomplete="username"></label>
    <label>Password <input name="session[password]" type="password" autocomplete="current-password"></label>
    <button class="btn btn-primary" type="submit">Sign in</button>
  </form>
  """
end
```

- [ ] **Step 2: Render invalid login with the same form and error panel**

In `SessionController.create/2`, replace the invalid-credentials branch body with:

```elixir
error_panel("Invalid username or password.") <>
  form_panel("Sign in", "Use your local Fornacast account to access repositories.", login_form())
```

Expected branch shape:

```elixir
{:error, :invalid_credentials} ->
  conn
  |> put_status(:unauthorized)
  |> page(
    "Login",
    error_panel("Invalid username or password.") <>
      form_panel("Sign in", "Use your local Fornacast account to access repositories.", login_form())
  )
```

- [ ] **Step 3: Refresh setup form bodies**

In `apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex`, replace `form_body/0` with:

```elixir
defp form_body do
  form_panel(
    "First administrator",
    "Create the first administrator account to finish setting up this Fornacast instance.",
    """
    <form action="/setup" method="post">
      #{csrf_input()}
      <label>Username <input name="admin[username]" autocomplete="username"></label>
      <label>Email <input name="admin[email]" type="email" autocomplete="email"></label>
      <label>Password <input name="admin[password]" type="password" autocomplete="new-password"></label>
      <button class="btn btn-primary" type="submit">Create admin</button>
    </form>
    """
  )
end
```

- [ ] **Step 4: Refresh setup error states**

In `SetupController`, replace `already_initialized/1` body and `error_body/1` with:

```elixir
defp already_initialized(conn) do
  conn
  |> put_status(:not_found)
  |> page("Not found", error_panel("Fornacast is already set up."))
end

defp error_body(changeset) do
  error_panel(inspect(changeset.errors)) <> form_body()
end
```

- [ ] **Step 5: Run utility-page tests**

Run:

```bash
mix test apps/fornacast_web/test/setup_wizard_test.exs apps/fornacast_web/test/fornacast_web_test.exs --trace
```

Expected: setup and login assertions pass; dashboard/repository/SSH-key assertions may still fail.

- [ ] **Step 6: Commit utility-page refresh**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/session_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex
git commit -m "feat(ui): refresh login and setup pages"
```

Expected: commit succeeds with only setup/login controller changes.

## Task 5: Refresh Dashboard, New Repository, and SSH Keys

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/dashboard_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Refresh dashboard table and empty state**

In `DashboardController.index/2`, build `rows` as before but give the table and visibility badge explicit classes:

```elixir
rows =
  repos
  |> Enum.map(fn repo ->
    """
    <tr>
      <td><a href="/#{escape(user.username)}/#{escape(repo.slug)}">#{escape(repo.name)}</a></td>
      <td>#{badge(repo.visibility, to_string(repo.visibility))}</td>
      <td><code>#{escape(repo.default_branch)}</code></td>
    </tr>
    """
  end)
  |> Enum.join("\n")
```

Then replace `body` with:

```elixir
body =
  section_header(
    "Repositories",
    "Browse repositories owned by #{user.username}.",
    primary_link("/repos/new", "New repository")
  ) <>
    if rows == "" do
      empty_state(
        "No repositories yet",
        "Create the first repository for this Fornacast instance.",
        primary_link("/repos/new", "Create repository")
      )
    else
      """
      <section class="content-panel">
        <table class="data-table repo-table">
          <thead><tr><th>Repository</th><th>Visibility</th><th>Default branch</th></tr></thead>
          <tbody>#{rows}</tbody>
        </table>
      </section>
      """
    end
```

- [ ] **Step 2: Add a reusable new-repository form body**

In `RepositoryController`, replace `new/2` body with:

```elixir
section_header("New repository", "Create a local Git repository.", "") <> repository_form()
```

Add this helper near the other private helpers:

```elixir
defp repository_form do
  form_panel(
    "Repository details",
    "Choose a short slug and default visibility for the repository.",
    """
    <form action="/repos" method="post">
      #{csrf_input()}
      <label>Name <input name="repository[name]"></label>
      <label>Slug <input name="repository[slug]"></label>
      <label>Description <textarea name="repository[description]" rows="3"></textarea></label>
      <label>Visibility
        <select name="repository[visibility]">
          <option value="private">Private</option>
          <option value="public">Public</option>
        </select>
      </label>
      <button class="btn btn-primary" type="submit">Create repository</button>
    </form>
    """
  )
end
```

- [ ] **Step 3: Refresh repository creation errors**

In `RepositoryController.create/2`, replace both error branches with:

```elixir
{:error, %Ecto.Changeset{} = changeset} ->
  conn
  |> put_status(:unprocessable_entity)
  |> page("New repository", error_panel(inspect(changeset.errors)) <> repository_form())

{:error, reason} ->
  conn
  |> put_status(:unprocessable_entity)
  |> page("New repository", error_panel(reason) <> repository_form())
```

- [ ] **Step 4: Refresh SSH-key page**

In `SSHKeyController.index/2`, keep the key listing but use these row and body shapes:

```elixir
rows =
  keys
  |> Enum.map(fn key ->
    """
    <tr>
      <td>#{escape(key.title)}</td>
      <td><code>#{escape(key.fingerprint_sha256)}</code></td>
      <td>
        <form action="/ssh-keys/#{key.id}" method="post">
          #{csrf_input()}
          <input type="hidden" name="_method" value="delete">
          <button class="btn btn-danger btn-compact" type="submit">Delete</button>
        </form>
      </td>
    </tr>
    """
  end)
  |> Enum.join("\n")
```

Use this page body:

```elixir
key_table =
  if rows == "" do
    empty_state("No SSH keys", "Add a public key to push repositories over SSH.")
  else
    """
    <section class="content-panel">
      <table class="data-table key-table">
        <thead><tr><th>Title</th><th>Fingerprint</th><th>Action</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </section>
    """
  end

page(conn, "SSH keys", """
#{section_header("SSH keys", "Manage SSH keys for Git transport.", "")}
<div class="settings-grid">
  #{ssh_key_form()}
  #{key_table}
</div>
""")
```

Add:

```elixir
defp ssh_key_form do
  form_panel(
    "Add SSH key",
    "Paste an OpenSSH public key from your workstation.",
    """
    <form action="/ssh-keys" method="post">
      #{csrf_input()}
      <label>Title <input name="ssh_key[title]"></label>
      <label>Public key <textarea name="ssh_key[public_key]" rows="5"></textarea></label>
      <button class="btn btn-primary" type="submit">Add key</button>
    </form>
    """
  )
end
```

- [ ] **Step 5: Refresh SSH-key validation errors**

In `SSHKeyController.create/2`, replace the error branch with:

```elixir
{:error, changeset} ->
  conn
  |> put_status(:unprocessable_entity)
  |> page("SSH keys", error_panel(inspect(changeset.errors)) <> ssh_key_form())
```

- [ ] **Step 6: Run focused web tests**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --trace
```

Expected: dashboard and SSH-key assertions pass; repository overview/source assertions may still fail until repository pages are refreshed.

- [ ] **Step 7: Commit dashboard/settings refresh**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/dashboard_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex
git commit -m "feat(ui): refresh dashboard and settings views"
```

Expected: commit succeeds with dashboard, SSH-key, and new-repository controller changes.

## Task 6: Refresh Repository Browser Pages

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Add repository header and tabs helpers**

In `RepositoryController`, add:

```elixir
defp repo_header(owner, repo) do
  description =
    repo.description
    |> to_string()
    |> case do
      "" -> "No description provided."
      value -> value
    end

  """
  <section class="repo-header">
    <div>
      <p class="eyebrow">Repository</p>
      <h2>#{escape(owner.username)} / #{escape(repo.slug)}</h2>
      <p class="muted">#{escape(description)}</p>
    </div>
    <div class="repo-meta">
      #{badge(repo.visibility, to_string(repo.visibility))}
      <span class="badge"><code>#{escape(repo.default_branch)}</code></span>
    </div>
  </section>
  """
end

defp repo_tabs(owner, repo, active) do
  base = "/#{escape(owner.username)}/#{escape(repo.slug)}"

  """
  <nav class="repo-tabs" aria-label="Repository navigation">
    #{repo_tab(base, "Code", active == :code)}
    #{repo_tab("#{base}/commits/#{escape(repo.default_branch)}", "Commits", active == :commits)}
    #{repo_tab("#{base}/branches", "Branches", active == :branches)}
    #{repo_tab("#{base}/tags", "Tags", active == :tags)}
  </nav>
  """
end

defp repo_tab(href, label, active?) do
  active_class = if active?, do: " is-active", else: ""
  ~s(<a class="tab-link#{active_class}" href="#{href}">#{escape(label)}</a>)
end
```

- [ ] **Step 2: Wrap repository show, branches, tags, commits, source, and commit detail bodies**

When rendering repository pages, prepend:

```elixir
repo_header(owner, repo) <> repo_tabs(owner, repo, :code)
```

Use `:branches` for branches, `:tags` for tags, and `:commits` for commits and commit detail pages. For source and file pages rendered by `render_src_path/6`, use `:code`.

Example replacement for `branches/2`:

```elixir
page(
  conn,
  "Branches: #{owner.username}/#{repo.slug}",
  repo_header(owner, repo) <> repo_tabs(owner, repo, :branches) <> refs_table(refs, "Branch")
)
```

- [ ] **Step 3: Refresh empty repository state**

Replace `empty_repository_body/2` with:

```elixir
defp empty_repository_body(owner, repo) do
  clone_url = ForgeRepos.ssh_clone_url(repo, owner)
  commands = """
  git init
  git remote add origin #{clone_url}
  git branch -M #{repo.default_branch}
  git push -u origin #{repo.default_branch}
  """

  empty_state(
    "Quick setup",
    "This repository is empty. Push an existing project to start browsing code.",
    """
    <h3>Clone URL</h3>
    #{command_block(clone_url)}
    <h3>Push an existing project</h3>
    #{command_block(String.trim(commands))}
    """
  )
end
```

- [ ] **Step 4: Refresh repository overview README panel**

Replace `repository_overview_body/2` with:

```elixir
defp repository_overview_body(_owner, repo) do
  """
  <section class="content-panel">
    <p class="muted">Default branch <code>#{escape(repo.default_branch)}</code></p>
  </section>
  #{readme_preview(repo)}
  """
end
```

Replace `render_readme/2` with:

```elixir
defp render_readme(path, blob) do
  content = to_string(blob.data)

  body =
    if String.ends_with?(String.downcase(path), ".md") do
      MDEx.to_html!(content, sanitize: MDEx.Document.default_sanitize_options())
    else
      code_block(content)
    end

  """
  <section class="readme-panel">
    <h3>#{escape(path)}</h3>
    #{body}
  </section>
  """
end
```

- [ ] **Step 5: Refresh refs and commits tables**

In `refs_table/2`, wrap the table with `class="data-table refs-table"`:

```elixir
"""
<section class="content-panel">
  <table class="data-table refs-table">
    <thead><tr><th>#{escape(label)}</th><th>Target</th></tr></thead>
    <tbody>#{rows}</tbody>
  </table>
</section>
"""
```

In `commits_table/3`, use:

```elixir
"""
<section class="content-panel">
  <table class="data-table commits-table">
    <thead><tr><th>Commit</th><th>Title</th><th>Author</th><th>Date</th></tr></thead>
    <tbody>#{rows}</tbody>
  </table>
</section>
"""
```

- [ ] **Step 6: Refresh source tree and file panels**

In `tree_view/5`, replace the leading path paragraph and table wrapper with:

```elixir
"""
<div class="path-bar"><code>#{escape(ref)}</code> / #{escape(browse_path)}</div>
#{up_link}
<section class="content-panel">
  <table class="data-table source-table">
    <thead><tr><th>Name</th><th>Kind</th><th>Object</th></tr></thead>
    <tbody>#{rows}</tbody>
  </table>
</section>
"""
```

In `blob_view/5`, replace the return body with:

```elixir
"""
<section class="file-panel">
  <div class="path-bar">
    <code>#{escape(ref)}</code> / #{escape(blob_path)} · #{blob.size} bytes · <a href="#{raw_url}">Raw</a>
  </div>
  #{body}
</section>
"""
```

Also replace the inline `<pre>` branches in `blob_view/5` with `code_block(blob.data)`.

- [ ] **Step 7: Refresh commit detail diff panels**

In `commit_detail/4`, wrap the summary in `content-panel` and keep all existing metadata:

```elixir
"""
<section class="content-panel">
  <p><code>#{escape(commit.oid)}</code></p>
  #{code_block(commit.message)}
  <table class="data-table commit-meta-table">
    <tbody>
      <tr><th>Author</th><td>#{escape(commit.author_name)} &lt;#{escape(commit.author_email)}&gt; #{escape(format_unix(commit.author_time))}</td></tr>
      <tr><th>Committer</th><td>#{escape(commit.committer_name)} &lt;#{escape(commit.committer_email)}&gt; #{escape(format_unix(commit.committer_time))}</td></tr>
      <tr><th>Parents</th><td>#{parents}</td></tr>
    </tbody>
  </table>
</section>
#{commit_diff(diff)}
"""
```

In `commit_diff/1`, wrap the changed-file table in `content-panel` and render the patch with `code_block(diff.patch)` instead of a plain `<pre>`.

- [ ] **Step 8: Run focused web tests**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --trace
```

Expected: all UI contract assertions and existing repository behavior assertions pass.

- [ ] **Step 9: Commit repository browser refresh**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex
git commit -m "feat(ui): refresh repository browser pages"
```

Expected: commit succeeds with only repository-controller changes.

## Task 7: Full Local Verification

**Files:**
- Review all changed files from Tasks 1-6.

- [ ] **Step 1: Format the code**

Run:

```bash
mix format
```

Expected: command exits 0. If formatting changes files, inspect `git diff --stat` and keep only formatting for files already modified by this plan.

- [ ] **Step 2: Run the focused web test suite**

Run:

```bash
mix test apps/fornacast_web/test
```

Expected: all tests under `apps/fornacast_web/test` pass.

- [ ] **Step 3: Compile production assets**

Run:

```bash
MIX_ENV=prod FORNACAST_DATABASE_ADAPTER=turso mix assets.deploy
```

Expected: command exits 0 and regenerated assets, if any, match the repo's existing asset-output conventions.

- [ ] **Step 4: Commit any formatting or asset-manifest cleanup**

If `git status --short` shows changes caused only by formatting or asset-manifest output, run:

```bash
git add apps/fornacast_web
git commit -m "chore(ui): format refreshed web views"
```

Expected: commit is created only if there are remaining intended changes.

## Task 8: Chrome DevTools Visual Verification

**Files:**
- Create screenshots under `tmp/ui-verification/` if screenshots are saved locally.
- Do not commit `tmp/ui-verification/`.

- [ ] **Step 1: Start the local app**

Run:

```bash
PORT=4890 mix fornacast.run
```

Expected: the app starts on `http://localhost:4890`. Keep the process running while using Chrome DevTools.

- [ ] **Step 2: Verify desktop pages**

Using Chrome DevTools MCP, visit these pages at a desktop viewport such as `1440x1000`:

```text
http://localhost:4890/setup
http://localhost:4890/login
http://localhost:4890/
http://localhost:4890/repos/new
http://localhost:4890/ssh-keys
http://localhost:4890/alice/demo
http://localhost:4890/alice/demo/src/main
http://localhost:4890/alice/demo/src/main/README.md
http://localhost:4890/alice/demo/commits/main
http://localhost:4890/alice/demo/branches
http://localhost:4890/alice/demo/tags
```

Expected: no console errors, no failed CSS/JS asset requests, the app shell is visible on authenticated pages, the utility shell is visible on setup/login, and source/code panels remain readable.

- [ ] **Step 3: Verify mobile pages**

Using Chrome DevTools MCP, switch to a mobile viewport such as `390x844` and revisit:

```text
http://localhost:4890/login
http://localhost:4890/
http://localhost:4890/ssh-keys
http://localhost:4890/alice/demo
http://localhost:4890/alice/demo/src/main/README.md
```

Expected: no horizontal page overflow, rail navigation stacks or scrolls cleanly, tables/code blocks scroll inside their containers, and text does not overlap.

- [ ] **Step 4: Run a browser layout sanity script**

In Chrome DevTools console, run:

```javascript
(() => {
  const overflow = document.documentElement.scrollWidth > document.documentElement.clientWidth;
  const emptyButtons = [...document.querySelectorAll("button, a")]
    .filter((node) => !node.textContent.trim() && !node.getAttribute("aria-label"));
  return {
    overflow,
    emptyInteractiveElements: emptyButtons.map((node) => node.outerHTML)
  };
})();
```

Expected: `overflow` is `false` for normal pages. Code and table blocks may scroll internally. `emptyInteractiveElements` is an empty array.

- [ ] **Step 5: Commit visual polish fixes if needed**

If Chrome DevTools reveals layout defects, fix only CSS/controller markup needed for those defects, then run:

```bash
mix test apps/fornacast_web/test
MIX_ENV=prod FORNACAST_DATABASE_ADAPTER=turso mix assets.deploy
git add apps/fornacast_web
git commit -m "fix(ui): polish responsive forge layout"
```

Expected: commit exists only if visual verification found and fixed concrete defects.

## Task 9: Final Review and Handoff

**Files:**
- Review final changed files only.

- [ ] **Step 1: Inspect final status and commit stack**

Run:

```bash
git status --short --branch
git log --oneline --decorate --max-count=10
```

Expected: the branch is clean except for intentionally uncommitted scratch files under `tmp/`, and the commit stack is split by test, helper shell, assets, utility pages, dashboard/settings, repository browser, and any visual polish.

- [ ] **Step 2: Summarize verification evidence**

Prepare a short handoff with:

```text
Implemented:
- Shared DuskMoon workbench shell and utility shell.
- Login/setup/dashboard/SSH-key/repository browser refresh.
- Forgejo-inspired repository header, tabs, tables, command blocks, and code panels.

Verified:
- mix test apps/fornacast_web/test
- MIX_ENV=prod FORNACAST_DATABASE_ADAPTER=turso mix assets.deploy
- Chrome DevTools desktop/mobile visual pass

Residual risk:
- Raw controller-rendered HTML remains intentionally simple; future large templates should move to focused helpers or templates.
```

Expected: final response is concise and includes any skipped verification or residual risk.

## Self-Review

- Spec coverage: Tasks 2-6 cover the DuskMoon shell, utility pages, dashboard, repository overview, empty repository state, source/file views, commits/branches/tags, SSH keys, and helper extraction. Task 8 covers desktop and mobile Chrome DevTools verification from the spec.
- Scope check: All planned edits stay inside the allowed files from the spec. No route, auth, data model, Git transport, database, or LiveView changes are planned.
- Placeholder scan: The plan avoids deferred-work markers and undefined helper names. Helpers introduced in earlier tasks are the helpers used by later tasks.
- Test strategy: Task 1 adds failing tests before UI implementation. Later tasks run scoped web tests after each page group, and Task 7 runs the full `apps/fornacast_web/test` suite plus production asset compilation.
