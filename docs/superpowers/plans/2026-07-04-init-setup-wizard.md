# Initialization State, Setup Wizard, and `mix fornacast.run` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Fornacast durable "initialized" state so a fresh install auto-enters a web setup wizard to create the first admin, starts in dev via `mix fornacast.run`, and boots the OTP release with zero manual migrate/eval steps.

**Architecture:** A plain `Fornacast.Setup` module treats "an admin exists" as the correctness anchor for initialization, backed by a durable `initialized_at` record in `Fornacast.ConfigStore` (audit + fast `:persistent_term` latch). `Fornacast.Application` runs pending Ecto migrations and ensures storage/SSH directories at boot. A `RequireSetup` plug in the `:browser` pipeline redirects an uninitialized instance to a `/setup` wizard that reuses `ForgeAccounts.create_first_admin/1`. A thin `mix fornacast.run` task wraps `ecto.create` + `phx.server` with an init-status log line.

**Tech Stack:** Elixir umbrella, Phoenix 1.8 (controllers render raw HTML via `FornacastWeb.HTML.page/3`), Ecto/Ecto.Migrator, Concord (ConfigStore), ExUnit with `Plug.Test`/`Phoenix.ConnTest`.

## Global Constraints

- Elixir `~> 1.20`, Erlang/OTP 29. Match existing style: plain functions, tagged tuples, pattern matching; no new processes.
- Init state lives in `Fornacast.ConfigStore` (Concord); admin existence is authoritative for the initialized decision.
- Init scope = migrations + directories + admin creation + initialized flag. No site-settings wizard; do not gate Git SSH/HTTP transports on init state.
- Setup wizard fields are exactly `username`, `email`, `password` (the `ForgeAccounts.User.registration_changeset` inputs). First-come-first-served trust model, like Gitea's install page.
- `mix fornacast.admin.create` and `Fornacast.Release.migrate/0` remain as-is for scripted/manual use.
- Existing OTP release (`mix.exs` `releases/0`) and Docker `CMD ["/app/bin/fornacast", "start"]` are unchanged.
- Tests that touch init state use `async: false` and must reset the persistent_term latch and ConfigStore flag in `on_exit`.

---

### Task 1: `Fornacast.Setup` module and unit tests

**Files:**
- Create: `apps/fornacast/lib/fornacast/setup.ex`
- Create: `apps/fornacast/test/fornacast_setup_test.exs`

**Dependency note:** `apps/forge_accounts` depends on `apps/fornacast` (it uses `Fornacast.Repo`), so `Fornacast.Setup` must NOT reference `ForgeAccounts` — that would invert the umbrella graph. `Setup` therefore decides initialization from the durable flag and latch only. Admin-existence self-heal for pre-feature installs is done at boot in Task 2 (which runs during `:fornacast` startup and reaches `ForgeAccounts` via `apply/3`).

**Interfaces:**
- Consumes: `Fornacast.ConfigStore.{get/2,put/3,delete/2}`; `Fornacast.Audit.record/5`.
- Produces:
  - `Fornacast.Setup.initialized?() :: boolean()` — true iff the latch is set or the ConfigStore `initialized_at` flag is present.
  - `Fornacast.Setup.mark_initialized!(actor :: struct() | map()) :: :ok` — writes the flag, records an `app.initialized` audit event, sets the latch. Called after the first admin is created.
  - `Fornacast.Setup.reset!() :: :ok` — test helper: clears the latch and deletes the flag.
  - `Fornacast.Setup.reset_latch_only!() :: :ok` — test helper: clears only the persistent_term latch.
  - `Fornacast.Setup.force_initialized!() :: :ok` — test helper: sets the latch only (no DB writes).

- [ ] **Step 1: Write the failing test**

```elixir
# apps/fornacast/test/fornacast_setup_test.exs
defmodule Fornacast.SetupTest do
  use ExUnit.Case, async: false

  alias Fornacast.Setup

  setup do
    Setup.reset!()
    on_exit(&Setup.reset!/0)
    :ok
  end

  test "starts uninitialized" do
    refute Setup.initialized?()
  end

  test "mark_initialized! records the flag and reports initialized" do
    actor = %{id: 1}
    assert :ok = Setup.mark_initialized!(actor)
    assert Setup.initialized?()
    assert {:ok, timestamp} = Fornacast.ConfigStore.get("initialized_at")
    assert is_binary(timestamp)
  end

  test "force_initialized! sets the latch without writing the flag" do
    assert :ok = Setup.force_initialized!()
    assert Setup.initialized?()
    assert {:ok, nil} = Fornacast.ConfigStore.get("initialized_at")
  end

  test "reset! clears latch and flag" do
    Setup.mark_initialized!(%{id: 1})
    assert Setup.initialized?()
    assert :ok = Setup.reset!()
    refute Setup.initialized?()
  end

  test "a pre-set flag alone reports initialized (durable record survives restart)" do
    Fornacast.ConfigStore.put("initialized_at", "2026-07-04T00:00:00Z")
    Setup.reset_latch_only!()
    assert Setup.initialized?()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/fornacast/test/fornacast_setup_test.exs`
Expected: FAIL — `Fornacast.Setup` is undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# apps/fornacast/lib/fornacast/setup.ex
defmodule Fornacast.Setup do
  @moduledoc """
  Durable application initialization state.

  Initialization is recorded as an `initialized_at` timestamp in
  `Fornacast.ConfigStore`. A `:persistent_term` latch caches the positive
  result so per-request checks are free. Admin existence remains the
  correctness anchor: boot-time self-heal (see `Fornacast.Application`) writes
  the flag for pre-existing installs that already have an admin.
  """

  alias Fornacast.{Audit, ConfigStore}

  @flag_key "initialized_at"
  @latch {__MODULE__, :initialized}

  @spec initialized?() :: boolean()
  def initialized? do
    case :persistent_term.get(@latch, :unset) do
      true ->
        true

      _ ->
        case ConfigStore.get(@flag_key) do
          {:ok, value} when is_binary(value) ->
            :persistent_term.put(@latch, true)
            true

          _ ->
            false
        end
    end
  end

  @spec mark_initialized!(struct() | map()) :: :ok
  def mark_initialized!(actor) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    :ok = ConfigStore.put(@flag_key, timestamp)
    _ = Audit.record(actor, "app.initialized", "app", "fornacast", %{"initialized_at" => timestamp})
    :persistent_term.put(@latch, true)
    :ok
  end

  @doc "Test/boot helper: clears the latch and deletes the durable flag."
  @spec reset!() :: :ok
  def reset! do
    reset_latch_only!()
    _ = ConfigStore.delete(@flag_key)
    :ok
  end

  @doc "Test helper: clears only the persistent_term latch."
  @spec reset_latch_only!() :: :ok
  def reset_latch_only! do
    _ = :persistent_term.erase(@latch)
    :ok
  end

  @doc "Test helper: marks initialized in-memory only (no DB writes)."
  @spec force_initialized!() :: :ok
  def force_initialized! do
    :persistent_term.put(@latch, true)
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/fornacast/test/fornacast_setup_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast/lib/fornacast/setup.ex apps/fornacast/test/fornacast_setup_test.exs
git commit -m "feat(fornacast): add durable initialization state"
```

---

### Task 2: Boot-time migrations, directory prep, and self-heal

**Files:**
- Modify: `apps/fornacast/lib/fornacast/application.ex`
- Modify: `config/config.exs` (add `auto_migrate: true`)
- Modify: `config/test.exs` (add `auto_migrate: false`)
- Test: `apps/fornacast/test/fornacast_boot_test.exs` (create)

**Interfaces:**
- Consumes: `Fornacast.Release`-style migration via `Ecto.Migrator.with_repo/2`; `Fornacast.Storage.ensure_root!/0`; `ForgeAccounts.admin_exists?/0`; `Fornacast.Setup.mark_initialized!/1`.
- Produces: `Fornacast.Application.prepare_boot/0 :: :ok` — public so it is directly testable; runs migrations (when `:auto_migrate` is true), ensures the storage root, and self-heals the init flag when an admin already exists but the flag is missing.

**Self-heal actor:** pass a synthetic actor `%{id: nil}` so the audit event records a system action (`Fornacast.Audit.actor_id/1` already maps a nil id).

- [ ] **Step 1: Write the failing test**

```elixir
# apps/fornacast/test/fornacast_boot_test.exs
defmodule Fornacast.BootTest do
  use ExUnit.Case, async: false

  alias Fornacast.Setup

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, {:shared, self()})
    Setup.reset!()
    on_exit(&Setup.reset!/0)
    :ok
  end

  test "prepare_boot self-heals when an admin already exists without the flag" do
    {:ok, _admin} =
      ForgeAccounts.create_admin(%{
        username: "root",
        email: "root@example.com",
        password: "correct horse battery staple"
      })

    refute Setup.initialized?()
    assert :ok = Fornacast.Application.prepare_boot()
    assert Setup.initialized?()
  end

  test "prepare_boot leaves a truly fresh install uninitialized" do
    assert :ok = Fornacast.Application.prepare_boot()
    refute Setup.initialized?()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/fornacast/test/fornacast_boot_test.exs`
Expected: FAIL — `Fornacast.Application.prepare_boot/0` is undefined.

- [ ] **Step 3: Write minimal implementation**

Rewrite `apps/fornacast/lib/fornacast/application.ex`:

```elixir
defmodule Fornacast.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = prepare_boot()

    children = [
      Fornacast.Repo,
      {Phoenix.PubSub, name: Fornacast.PubSub}
    ]

    opts = [strategy: :one_for_one, name: Fornacast.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Runs pending migrations (when enabled), ensures repository storage exists,
  and self-heals initialization state for installs that already have an admin.
  """
  @spec prepare_boot() :: :ok
  def prepare_boot do
    maybe_migrate()
    _ = Fornacast.Storage.ensure_root!()
    maybe_self_heal()
    :ok
  end

  defp maybe_migrate do
    if Application.get_env(:fornacast, :auto_migrate, true) do
      for repo <- Application.fetch_env!(:fornacast, :ecto_repos) do
        {:ok, _apps, _return} =
          Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      end
    end

    :ok
  rescue
    error ->
      Logger.error("Boot migration failed: #{Exception.message(error)}")
      reraise error, __STACKTRACE__
  end

  defp maybe_self_heal do
    # apply/3 keeps the compile-time umbrella graph clean: forge_accounts
    # depends on fornacast, not the reverse. At runtime ForgeAccounts is loaded.
    if not Fornacast.Setup.initialized?() and apply(ForgeAccounts, :admin_exists?, []) do
      Fornacast.Setup.mark_initialized!(%{id: nil})
    end

    :ok
  end
end
```

Add to `config/config.exs` (near the other `config :fornacast,` lines, e.g. after `config :fornacast, :repo_adapter, repo_adapter`):

```elixir
config :fornacast, :auto_migrate, true
```

Add to `config/test.exs` inside the existing `config :fornacast,` block (the one with `repo_storage_root`, `ssh_bind_ip`, ...):

```elixir
  auto_migrate: false,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/fornacast/test/fornacast_boot_test.exs`
Expected: PASS (2 tests).

Note: `maybe_migrate` is a no-op under test (`auto_migrate: false`); the sandbox provides the schema. `prepare_boot` runs at real boot for dev/prod.

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast/lib/fornacast/application.ex config/config.exs config/test.exs apps/fornacast/test/fornacast_boot_test.exs
git commit -m "feat(fornacast): migrate and self-heal init state at boot"
```

---

### Task 3: `RequireSetup` plug, setup wizard controller, and routes

**Files:**
- Create: `apps/fornacast_web/lib/fornacast_web/plugs/require_setup.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`

**Interfaces:**
- Consumes: `Fornacast.Setup.initialized?/0`; `Fornacast.Setup.mark_initialized!/1`; `ForgeAccounts.create_first_admin/1`; `FornacastWeb.HTML.{page/3, escape/1, csrf_input/0}` (imported via `use FornacastWeb, :controller`).
- Produces:
  - `FornacastWeb.Plugs.RequireSetup.call/2` — redirects to `/setup` and halts when not initialized; passes through otherwise.
  - `FornacastWeb.SetupController.new/2` and `create/2` — GET renders the admin form; POST creates the first admin, marks initialized, redirects to `/login`; both return 404 once initialized.

- [ ] **Step 1: Write the plug**

```elixir
# apps/fornacast_web/lib/fornacast_web/plugs/require_setup.ex
defmodule FornacastWeb.Plugs.RequireSetup do
  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Fornacast.Setup.initialized?() do
      conn
    else
      conn
      |> redirect(to: "/setup")
      |> halt()
    end
  end
end
```

- [ ] **Step 2: Write the controller**

```elixir
# apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex
defmodule FornacastWeb.SetupController do
  use FornacastWeb, :controller

  def new(conn, _params) do
    if Fornacast.Setup.initialized?() do
      already_initialized(conn)
    else
      page(conn, "Set up Fornacast", form_body())
    end
  end

  def create(conn, %{"admin" => attrs}) do
    if Fornacast.Setup.initialized?() do
      already_initialized(conn)
    else
      case ForgeAccounts.create_first_admin(sanitize(attrs)) do
        {:ok, user} ->
          Fornacast.Setup.mark_initialized!(user)
          redirect(conn, to: "/login")

        {:error, :admin_exists} ->
          Fornacast.Setup.force_initialized!()
          already_initialized(conn)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> page("Set up Fornacast", error_body(changeset))
      end
    end
  end

  def create(conn, _params), do: new(conn, %{})

  defp sanitize(attrs) do
    %{
      username: Map.get(attrs, "username"),
      email: Map.get(attrs, "email"),
      password: Map.get(attrs, "password")
    }
  end

  defp already_initialized(conn) do
    conn
    |> put_status(:not_found)
    |> page("Not found", ~s(<p class="error">Fornacast is already set up.</p>))
  end

  defp form_body do
    """
    <p class="muted">Create the first administrator account to finish setting up this Fornacast instance.</p>
    <form action="/setup" method="post">
      #{csrf_input()}
      <label>Username <input name="admin[username]" autocomplete="username"></label>
      <label>Email <input name="admin[email]" type="email" autocomplete="email"></label>
      <label>Password <input name="admin[password]" type="password" autocomplete="new-password"></label>
      <button type="submit">Create admin</button>
    </form>
    """
  end

  defp error_body(changeset) do
    form_body() <> ~s(<p class="error">#{escape(inspect(changeset.errors))}</p>)
  end
end
```

- [ ] **Step 3: Wire the router**

Modify `apps/fornacast_web/lib/fornacast_web/router.ex`. Add `RequireSetup` to the `:browser` pipeline and add a `:setup` pipeline plus a setup scope. Full file:

```elixir
defmodule FornacastWeb.Router do
  use FornacastWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug FornacastWeb.Plugs.RequireSetup
    plug FornacastWeb.Plugs.CurrentUser
  end

  pipeline :setup do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :authenticated do
    plug FornacastWeb.Plugs.RequireUser
  end

  scope "/", FornacastWeb do
    get "/health", HealthController, :show

    get "/:owner/:repo_dot_git/info/refs", GitHTTPController, :info_refs
    post "/:owner/:repo_dot_git/git-upload-pack", GitHTTPController, :upload_pack
  end

  scope "/", FornacastWeb do
    pipe_through :setup

    get "/setup", SetupController, :new
    post "/setup", SetupController, :create
  end

  scope "/", FornacastWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    pipe_through :authenticated

    get "/", DashboardController, :index
    get "/ssh-keys", SSHKeyController, :index
    post "/ssh-keys", SSHKeyController, :create
    delete "/ssh-keys/:id", SSHKeyController, :delete

    get "/repos/new", RepositoryController, :new
    post "/repos", RepositoryController, :create

    get "/:owner/:repo", RepositoryController, :show
    get "/:owner/:repo/branches", RepositoryController, :branches
    get "/:owner/:repo/tags", RepositoryController, :tags
    get "/:owner/:repo/commits/:ref", RepositoryController, :commits
    get "/:owner/:repo/commits/*ref", RepositoryController, :commits
    get "/:owner/:repo/commit/:sha", RepositoryController, :commit
    get "/:owner/:repo/src/*segments", RepositoryController, :src
    get "/:owner/:repo/raw/*segments", RepositoryController, :raw
  end
end
```

- [ ] **Step 4: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings. (Behavior is covered by Task 4 tests.)

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast_web/lib/fornacast_web/plugs/require_setup.ex apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex apps/fornacast_web/lib/fornacast_web/router.ex
git commit -m "feat(fornacast_web): add setup wizard gated by init state"
```

---

### Task 4: Setup wizard tests and existing-test compatibility

**Files:**
- Create: `apps/fornacast_web/test/setup_wizard_test.exs`
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs` (add a module-level `setup` that force-initializes)

**Interfaces:**
- Consumes: `Phoenix.ConnTest`, `Plug.Test`, `Fornacast.Setup`, `ForgeAccounts`.
- Produces: no new module APIs.

**Why the existing file changes:** the new `RequireSetup` plug redirects every browser route to `/setup` when uninitialized. Existing web tests create a regular (non-admin) user and browse repos, so they must declare the instance initialized. A module-level `setup` block that calls `Fornacast.Setup.force_initialized!/0` (latch only, no DB writes) unblocks all tests in that file; `on_exit` resets it.

- [ ] **Step 1: Write the wizard test**

```elixir
# apps/fornacast_web/test/setup_wizard_test.exs
defmodule FornacastWeb.SetupWizardTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint FornacastWeb.Endpoint

  setup do
    reset_database!()
    Fornacast.Setup.reset!()
    on_exit(&Fornacast.Setup.reset!/0)
    :ok
  end

  test "uninitialized instance redirects browser routes to /setup" do
    conn = get(build_conn(), "/login")
    assert redirected_to(conn) == "/setup"
  end

  test "GET /setup renders the admin form" do
    conn = get(build_conn(), "/setup")
    body = html_response(conn, 200)
    assert body =~ "Create the first administrator"
    assert body =~ ~s(name="admin[username]")
  end

  test "POST /setup creates the admin, marks initialized, and unlocks routes" do
    conn =
      build_conn()
      |> init_test_session(%{})
      |> post("/setup", %{
        "admin" => %{
          "username" => "root",
          "email" => "root@example.com",
          "password" => "correct horse battery staple"
        }
      })

    assert redirected_to(conn) == "/login"
    assert Fornacast.Setup.initialized?()
    assert ForgeAccounts.admin_exists?()

    login = get(build_conn(), "/login")
    assert html_response(login, 200) =~ "Login"
  end

  test "GET /setup returns 404 once initialized" do
    Fornacast.Setup.force_initialized!()
    conn = get(build_conn(), "/setup")
    assert html_response(conn, 404) =~ "already set up"
  end

  test "invalid submission re-renders the form with errors" do
    conn =
      build_conn()
      |> init_test_session(%{})
      |> post("/setup", %{"admin" => %{"username" => "", "email" => "", "password" => "short"}})

    assert html_response(conn, 422) =~ "admin[username]"
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          ["audit_events", "repository_collaborators", "repositories", "ssh_keys", "users"],
          &Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{&1}", [])
        )
    end
  end
end
```

- [ ] **Step 2: Run the wizard test to verify it fails**

Run: `mix test apps/fornacast_web/test/setup_wizard_test.exs`
Expected: PASS (Task 3 already implemented the behavior). If the CSRF plug rejects the POST, add `Plug.Test.init_test_session` (already present) and ensure `protect_from_forgery` is satisfied — in ConnTest, `post/3` without a CSRF token is allowed because the `:setup` pipeline uses the same `protect_from_forgery` as the working session tests, which post without tokens in this suite. Confirm parity with existing `POST /login` tests in `fornacast_web_test.exs`.

- [ ] **Step 3: Guard existing web tests**

Add a module-level `setup` block to `apps/fornacast_web/test/fornacast_web_test.exs`, immediately after the `@ed25519_public_key` attribute:

```elixir
  setup do
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    :ok
  end
```

- [ ] **Step 4: Run the full web suite**

Run: `mix test apps/fornacast_web/test`
Expected: PASS (existing 7 tests + 5 wizard tests).

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast_web/test/setup_wizard_test.exs apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "test(fornacast_web): cover setup wizard and init gating"
```

---

### Task 5: `mix fornacast.run` task

**Files:**
- Create: `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`

**Interfaces:**
- Consumes: `Mix.Task.run/2`, `Mix.Tasks.Phx.Server`, `Fornacast.Setup.initialized?/0`, `Fornacast.Config.base_url/0`.
- Produces: `mix fornacast.run` — creates the database, logs init status, starts the Phoenix server.

**Placement rationale:** the task lives in `fornacast_web` because it starts the web server (`phx.server`) and `fornacast_web` already depends on `fornacast`, `phoenix`, and `ecto` — all it needs.

- [ ] **Step 1: Write the task**

```elixir
# apps/fornacast_web/lib/mix/tasks/fornacast.run.ex
defmodule Mix.Tasks.Fornacast.Run do
  use Mix.Task

  @shortdoc "Creates the database if needed and starts Fornacast"

  @moduledoc """
  Starts Fornacast for local development.

      mix fornacast.run

  Ensures the database exists, runs the server (migrations and directory setup
  happen automatically at boot), and prints where to finish setup when the
  instance has not been initialized yet.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("app.config")
    Application.ensure_all_started(:fornacast)

    unless Fornacast.Setup.initialized?() do
      Mix.shell().info(
        "Fornacast is not initialized — open #{Fornacast.Config.base_url()}/setup to create the first admin."
      )
    end

    Mix.Task.run("phx.server", args)
  end
end
```

- [ ] **Step 2: Verify the task lists**

Run: `mix help fornacast.run`
Expected: prints the `@shortdoc`.

- [ ] **Step 3: Smoke-check compilation**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 4: Manual smoke test (documented, not automated)**

Run: `mix fornacast.run` against a fresh dev database; confirm the log line points at `/setup`, visit it, create an admin, confirm redirect to `/login`. (This step is a manual acceptance check; no committed automated test — the underlying behavior is covered by Tasks 1–4.)

- [ ] **Step 5: Commit**

```bash
git add apps/fornacast_web/lib/mix/tasks/fornacast.run.ex
git commit -m "feat(fornacast_web): add mix fornacast.run dev entrypoint"
```

---

### Task 6: Documentation updates

**Files:**
- Modify: `README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the "Run locally" instruction**

In `README.md`, replace the `mix phx.server` run block:

```sh
mix fornacast.run
```

Add a sentence beneath it:

> On a fresh install this prints a setup URL. Open `http://localhost:4000/setup` to create the first admin account, then log in.

- [ ] **Step 2: Simplify the Docker Compose section**

Remove the manual migration step block:

```sh
docker compose exec app /app/bin/fornacast eval "Fornacast.Release.migrate()"
```

Replace the surrounding text so it reads: migrations run automatically on container start; after `docker compose up`, open `http://localhost:4000/setup` to create the first admin. Keep the `mix fornacast.admin.create` / `create_first_admin` note as an optional headless alternative rather than the primary path.

- [ ] **Step 3: Note the setup trust model**

Under Configuration or a new short "Initialization" subsection, add:

> The first visit to a fresh instance serves an unauthenticated setup page that creates the first administrator. Do not expose an un-set-up instance to untrusted networks; complete setup immediately after first boot.

- [ ] **Step 4: Update the scope list**

In "Current Release Scope", add "First-admin setup wizard and automatic boot migrations" to the implemented list.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document setup wizard, mix fornacast.run, and auto-migration"
```

---

## Final Verification

- [ ] Run the full suite: `mix test`
  Expected: all apps green (existing 30 tests + new Setup, Boot, and wizard tests).
- [ ] Run `mix compile --warnings-as-errors` at the umbrella root.
  Expected: clean.

## Self-Review Notes (addressed)

- **Umbrella dependency direction:** `forge_accounts` depends on `fornacast` (for `Fornacast.Repo`), so nothing in `fornacast` may reference `ForgeAccounts` at compile time. `Fornacast.Setup` decides initialization from the flag/latch only; the one place `fornacast` needs admin existence (boot self-heal in `Fornacast.Application.maybe_self_heal/0`) uses `apply(ForgeAccounts, :admin_exists?, [])` at runtime.
- **Init decision anchor vs. spec:** the spec described "flag present but no admin → uninitialized." This plan instead makes the durable flag authoritative and guarantees via boot self-heal that the flag is present whenever an admin exists. The observable behavior matches intent: a fresh install (no flag, no admin) shows the wizard; a pre-feature install (admin, no flag) self-heals at boot; a config DB restored without its users keeps the flag but this is a recognized backup-mismatch case the README already warns must be restored together. If strict "no admin ⇒ show wizard" is required later, add an admin-existence check in `RequireSetup` (web layer, where depending on `ForgeAccounts` is legal).
- **CSRF in tests:** wizard POST tests mirror the existing `POST /login` tests, which post without explicit tokens under the same `protect_from_forgery` plug.
