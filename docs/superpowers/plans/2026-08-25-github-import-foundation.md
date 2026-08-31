# GitHub Import Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add linked GitHub identities, encrypted saved/one-time PAT custody, durable import-plan persistence, a bounded GitHub REST client, and web-only repository/organization discovery.

**Architecture:** A new `forge_imports` umbrella app coordinates GitHub calls and persists safe import plans while `ForgeAccounts` remains authoritative for identities and credentials. This milestone stops at `awaiting_resolution`: it performs no Git clone, organization creation, hidden repository creation, or publication.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto 3.14, Turso/PostgreSQL, Req 0.7, Phoenix 1.8, PhoenixDuskmoon 9.12

---

**Design:** `docs/superpowers/specs/2026-08-25-github-repository-organization-import-design.md`

**Milestone boundary:** This plan implements delivery milestone 1 only. Continue with `2026-08-25-github-repository-import.md` after every acceptance check here passes.

**Command convention:** The pinned shell does not include `unbuffer`. Run every Mix command in this plan through:

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix <task-and-arguments>
```

The initial isolated-worktree baseline produced one parallel Turso `database is locked` failure at `apps/forge_pulls/test/forge_pulls_test.exs:516`; the exact test passed serially with `--max-cases 1`. Keep all focused database suites in this plan serial.

## File and module map

- `apps/forge_imports/`: new orchestration app; it depends on domains but owns no account/repository schema.
- `ForgeAccounts.Namespace`: shared validation for newly created namespace slugs.
- `ForgeAccounts.GitHubIdentity`: stable GitHub actor identity and optional local-user link.
- `ForgeAccounts.GitHubCredential`: encrypted saved PAT envelope metadata.
- `ForgeAccounts.GitHubCredentialVault`: AEAD/keyring boundary; raw PAT access is callback-only.
- `ForgeAccounts.GitHubAccounts`: transactional account-link and credential lifecycle implementation.
- `ForgeImports.ImportRun` and `RepositoryItem`: durable discovery plan and per-source-repository state.
- `ForgeImports.ImportAttempt`, `ObjectMapping`, `PageCheckpoint`, and `ReportEntry`: durable history/checkpoint primitives used immediately by discovery and later milestones.
- `ForgeImports.GitHub.RepositoryReference`: strict GitHub.com source parser.
- `ForgeImports.GitHub.Client`: fixed-host, versioned, bounded REST client.
- `ForgeImports.Discovery`: source discovery and collision/warning planner.
- `FornacastWeb.GitHubSettingsController/HTML`: linked-account settings.
- `FornacastWeb.ImportController/HTML`: repository and organization discovery pages.

### Task 1: Scaffold the `forge_imports` umbrella app

**Files:**

- Create: `apps/forge_imports/mix.exs`
- Create: `apps/forge_imports/lib/forge_imports.ex`
- Create: `apps/forge_imports/lib/forge_imports/application.ex`
- Create: `apps/forge_imports/test/test_helper.exs`
- Create: `apps/forge_imports/test/forge_imports_test.exs`
- Modify: `mix.exs`
- Modify: `apps/fornacast_web/mix.exs`

- [ ] **Step 1: Write the failing umbrella-boundary test**

```elixir
defmodule ForgeImportsTest do
  use ExUnit.Case, async: true

  test "the coordinator exposes the supported provider" do
    assert ForgeImports.provider() == :github
  end
end
```

- [ ] **Step 2: Run the new app test and verify the app is absent**

Run:

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/forge_imports_test.exs
```

Expected: FAIL because `apps/forge_imports` is not an umbrella child.

- [ ] **Step 3: Create the app and wire dependencies**

Use this project definition:

```elixir
defmodule ForgeImports.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_imports,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {ForgeImports.Application, []}]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:forge_repos, in_umbrella: true},
      {:ecto, "~> 3.14"},
      {:req, "~> 0.7"}
    ]
  end
end
```

Use an empty supervised boundary initially:

```elixir
defmodule ForgeImports.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: ForgeImports.Supervisor)
  end
end

defmodule ForgeImports do
  @moduledoc "GitHub import discovery and durable orchestration."

  def provider, do: :github
end
```

Add `forge_imports: :permanent` after `forge_repos` and before presentation apps in the root release. Add `{:forge_imports, in_umbrella: true}` to `fornacast_web`.

- [ ] **Step 4: Verify compilation and the new test**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix deps.get
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix compile --warnings-as-errors
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/forge_imports_test.exs
```

Expected: compilation succeeds and `1 test, 0 failures`.

- [ ] **Step 5: Commit the scaffold**

```bash
git add mix.exs apps/fornacast_web/mix.exs apps/forge_imports
git commit -m "feat(import): add GitHub import application"
```

### Task 2: Centralize reserved namespace validation

**Files:**

- Create: `apps/forge_accounts/lib/forge_accounts/namespace.ex`
- Create: `apps/forge_accounts/test/namespace_test.exs`
- Modify: `apps/forge_accounts/lib/forge_accounts/user.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts/organization.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`

- [ ] **Step 1: Write failing validation tests**

```elixir
defmodule ForgeAccounts.NamespaceTest do
  use ExUnit.Case, async: true

  alias ForgeAccounts.Namespace

  test "rejects every reserved root route" do
    for slug <- ~w(assets health setup login logout issues pulls ssh-keys settings organizations repos imports api .well-known) do
      assert {:error, :reserved} = Namespace.validate(slug)
    end
  end

  test "normalizes and accepts an ordinary namespace" do
    assert {:ok, "acme-labs"} = Namespace.validate(" Acme-Labs ")
  end
end
```

Add registration/organization changeset assertions proving `repos` is rejected for new rows while existing rows remain readable.

- [ ] **Step 2: Run the tests and verify the missing module failure**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/namespace_test.exs --max-cases 1
```

Expected: FAIL with `ForgeAccounts.Namespace` undefined.

- [ ] **Step 3: Add the validator and changeset hook**

```elixir
defmodule ForgeAccounts.Namespace do
  @reserved MapSet.new(~w(
    .well-known api assets health imports issues login logout organizations pulls repos settings setup ssh-keys
  ))

  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid | :reserved}
  def validate(value) when is_binary(value) do
    slug = value |> String.trim() |> String.downcase()

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9_-]{1,38}[a-z0-9]$/, slug) -> {:error, :invalid}
      MapSet.member?(@reserved, slug) -> {:error, :reserved}
      true -> {:ok, slug}
    end
  end

  def validate(_value), do: {:error, :invalid}
  def reserved?(value), do: match?({:error, :reserved}, validate(value))
end
```

Add a private changeset validator to both account schemas that adds `"is reserved"` to `:username`. Delegate `validate_namespace_slug/1` and `reserved_namespace?/1` from `ForgeAccounts`.

- [ ] **Step 4: Run account tests serially**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/namespace_test.exs apps/forge_accounts/test/forge_accounts_test.exs --max-cases 1
```

Expected: all tests pass; no existing account fixture changes are required.

- [ ] **Step 5: Commit namespace validation**

```bash
git add apps/forge_accounts/lib/forge_accounts apps/forge_accounts/lib/forge_accounts.ex apps/forge_accounts/test
git commit -m "feat(accounts): reserve application namespaces"
```

### Task 3: Persist GitHub identities and the deleted-user sentinel

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260825000100_create_github_identities.exs`
- Create: `apps/forge_accounts/lib/forge_accounts/github_identity.ex`
- Create: `apps/forge_accounts/test/github_identity_test.exs`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`

- [ ] **Step 1: Write failing identity tests**

Cover stable 64-bit ID upsert, mutable login refresh, multiple identities linked to one local user, rejection when an identity is linked elsewhere, unlink without deletion, validated HTTPS profile URLs, and the singleton `Github:ghost` record.

```elixir
test "one local user links multiple identities while one identity links once" do
  user = user_fixture("alice")
  assert {:ok, first} = ForgeAccounts.observe_github_identity(profile(9_000_000_001, "alice-gh"), now())
  assert {:ok, second} = ForgeAccounts.observe_github_identity(profile(9_000_000_002, "alice-work"), now())
  assert {:ok, _} = ForgeAccounts.link_github_identity(user, first)
  assert {:ok, _} = ForgeAccounts.link_github_identity(user, second)
  assert Enum.map(ForgeAccounts.list_github_identities(user), & &1.github_user_id) == [9_000_000_001, 9_000_000_002]
end

test "deleted authors share a non-linkable sentinel" do
  assert %{kind: :deleted, login: "ghost"} = first = ForgeAccounts.github_deleted_identity()
  assert %{id: first.id} = ForgeAccounts.github_deleted_identity()
  assert ForgeAccounts.GitHubIdentity.display_name(first) == "Github:ghost"
end
```

- [ ] **Step 2: Run the tests before the migration**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_identity_test.exs --max-cases 1
```

Expected: FAIL because the schema/table does not exist.

- [ ] **Step 3: Add the migration and schema**

Create `github_identities` with `kind`, nullable `:bigint github_user_id`, login/profile fields, nullable local-user FK, verification timestamps, and UTC timestamps. Add:

```elixir
create unique_index(:github_identities, [:github_user_id],
         where: "github_user_id is not null",
         name: :github_identities_user_id_index
       )

create unique_index(:github_identities, [:kind],
         where: "kind = 'deleted'",
         name: :github_identities_deleted_singleton_index
       )
```

Use schema fields and public changesets:

```elixir
schema "github_identities" do
  field :kind, Ecto.Enum, values: [:user, :deleted]
  field :github_user_id, :integer
  field :login, :string
  field :avatar_url, :string
  field :profile_url, :string
  field :local_user_id, :integer
  field :last_verified_at, :utc_datetime
  field :last_observed_at, :utc_datetime
  timestamps(type: :utc_datetime)
end

def display_name(%__MODULE__{login: login}), do: "Github:" <> login
```

`observe_github_identity/2` upserts by numeric ID without treating login as identity. `github_deleted_identity/0` inserts or returns the single deleted row and never links it.

- [ ] **Step 4: Migrate and run identity tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix ecto.migrate
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_identity_test.exs --max-cases 1
```

Expected: all identity tests pass on Turso.

- [ ] **Step 5: Commit GitHub identities**

```bash
git add apps/fornacast/priv/repo/migrations/20260825000100_create_github_identities.exs apps/forge_accounts
git commit -m "feat(accounts): persist GitHub identities"
```

### Task 4: Add the credential keyring and AEAD vault

**Files:**

- Create: `apps/forge_accounts/lib/forge_accounts/github_credential.ex`
- Create: `apps/forge_accounts/lib/forge_accounts/github_credential_vault.ex`
- Create: `apps/forge_accounts/test/github_credential_vault_test.exs`
- Create: `apps/fornacast/priv/repo/migrations/20260825000200_create_github_credentials.exs`
- Modify: `apps/fornacast/lib/fornacast/config.ex`
- Modify: `apps/fornacast/lib/fornacast/audit.ex`
- Modify: `apps/fornacast/test/fornacast_test.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Modify: `README.md`
- Modify: `.env.example`

- [ ] **Step 1: Write vault and redaction tests**

Test nondeterministic ciphertext, 12-byte nonce, 16-byte tag, AAD binding, old-key reads, active-key writes, wrong/missing key failures, redacted `Inspect`, and nested audit filtering for `pat`, `github_pat`, `access_token`, `authorization`, `ciphertext`, `nonce`, `tag`, and `credential_envelope`.

```elixir
test "ciphertext is bound to the saved credential identity" do
  envelope = vault().encrypt_saved(%{id: 7, local_user_id: 4, github_identity_id: 9}, "github_pat_secret")
  assert {:ok, "github_pat_secret"} = vault().decrypt_saved(envelope, %{id: 7, local_user_id: 4, github_identity_id: 9})
  assert {:error, :credential_service_unavailable} = vault().decrypt_saved(envelope, %{id: 8, local_user_id: 4, github_identity_id: 9})
end
```

- [ ] **Step 2: Run the focused tests and verify failure**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_credential_vault_test.exs apps/fornacast/test/fornacast_test.exs --max-cases 1
```

Expected: FAIL because the vault and expanded redaction are absent.

- [ ] **Step 3: Implement AES-256-GCM and fail-closed configuration**

Use `:crypto.crypto_one_time_aead/7` with this envelope contract:

```elixir
@enforce_keys [:ciphertext, :nonce, :tag, :key_id]
defstruct @enforce_keys

def encrypt(plaintext, aad, %{active: key_id, keys: keys}) do
  key = Map.fetch!(keys, key_id)
  nonce = :crypto.strong_rand_bytes(12)
  {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, 16, true)
  {:ok, %__MODULE__{ciphertext: ciphertext, nonce: nonce, tag: tag, key_id: key_id}}
end
```

Parse production `FORNACAST_GITHUB_CREDENTIAL_KEYS` as a JSON object of key ID to base64-encoded 32-byte key and `FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID` as the write key. Missing/malformed configuration returns `{:error, :credential_service_unavailable}` from `Fornacast.Config.github_credential_keyring/0`; it does not stop unrelated applications. Configure a fixed test-only key in `config/test.exs`.

Create `20260825000200_create_github_credentials.exs` with one active row per identity, record ownership, binary envelope columns, `valid | invalid` status, and verification timestamps.

- [ ] **Step 4: Verify vault, config, and audit behavior**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_credential_vault_test.exs apps/fornacast/test/fornacast_test.exs --max-cases 1
```

Expected: all tests pass and failure messages contain no plaintext PAT.

- [ ] **Step 5: Commit the vault**

```bash
git add .env.example README.md config apps/fornacast/lib/fornacast/config.ex apps/fornacast/lib/fornacast/audit.ex apps/fornacast/test/fornacast_test.exs apps/fornacast/priv/repo/migrations/20260825000200_create_github_credentials.exs apps/forge_accounts
git commit -m "feat(accounts): encrypt GitHub credentials"
```

### Task 5: Implement transactional GitHub-account lifecycle APIs

**Files:**

- Create: `apps/forge_accounts/lib/forge_accounts/github_account_view.ex`
- Create: `apps/forge_accounts/lib/forge_accounts/github_accounts.ex`
- Create: `apps/forge_accounts/test/github_accounts_test.exs`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`

- [ ] **Step 1: Write failing account-lifecycle tests**

Cover save, callback-only checkout, transactional replacement, delete credential while retaining the link, unlink while deleting the saved credential, multiple accounts, disabled local users, identity collision masking, and sanitized audit rows.

```elixir
assert {:ok, %ForgeAccounts.GitHubAccountView{login: "octocat", credential_status: :valid}} =
         ForgeAccounts.save_github_account(actor, profile, pat, request_metadata)

assert {:ok, :used} =
         ForgeAccounts.with_github_credential(actor, github_identity.id, fn checked_out ->
           assert checked_out == pat
           :used
         end)
```

- [ ] **Step 2: Verify the public APIs are missing**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_accounts_test.exs --max-cases 1
```

Expected: FAIL with missing `ForgeAccounts.save_github_account/4`.

- [ ] **Step 3: Implement the context boundary**

Delegate these exact functions from `ForgeAccounts` to `GitHubAccounts`:

```elixir
list_github_accounts(actor)
save_github_account(actor, verified_profile, pat, request_metadata)
replace_github_credential(actor, identity_id, verified_profile, pat, request_metadata)
refresh_github_account(actor, identity_id, verified_profile, request_metadata)
delete_github_credential(actor, identity_id, request_metadata)
unlink_github_account(actor, identity_id, request_metadata)
with_github_credential(actor, identity_id, callback)
```

Use `Ecto.Multi` for identity/link/credential/audit changes. Insert a transaction-local credential row to obtain its ID, encrypt with ID-bound AAD, then update the envelope before commit. Never return the PAT from a public result or view.

- [ ] **Step 4: Run account and audit tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_accounts/test/github_accounts_test.exs apps/forge_accounts/test/github_identity_test.exs apps/fornacast/test/fornacast_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit account lifecycle behavior**

```bash
git add apps/forge_accounts apps/fornacast/test/fornacast_test.exs
git commit -m "feat(accounts): manage linked GitHub accounts"
```

### Task 6: Persist durable import runs, items, attempts, mappings, checkpoints, and reports

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260825000300_create_github_import_domain.exs`
- Create: `apps/forge_imports/lib/forge_imports/import_run.ex`
- Create: `apps/forge_imports/lib/forge_imports/repository_item.ex`
- Create: `apps/forge_imports/lib/forge_imports/import_attempt.ex`
- Create: `apps/forge_imports/lib/forge_imports/object_mapping.ex`
- Create: `apps/forge_imports/lib/forge_imports/page_checkpoint.ex`
- Create: `apps/forge_imports/lib/forge_imports/report_entry.ex`
- Create: `apps/forge_imports/lib/forge_imports/run_view.ex`
- Create: `apps/forge_imports/lib/forge_imports/one_time_credential.ex`
- Create: `apps/forge_imports/test/import_persistence_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`

- [ ] **Step 1: Write failing persistence/state-machine tests**

Test actor-scoped reads, foreign-run masking, complete approved state enums, selected-by-default items, positive 64-bit source IDs, immutable terminal rows, exact-one credential source, terminal one-time-envelope clearing, predecessor links, run/item lease changesets compatible with `Fornacast.OperationLease`, unique source mappings, checkpoint uniqueness, and bounded report details.

```elixir
test "terminal transition clears one-time credential atomically" do
  run = one_time_run_fixture(:running)
  assert {:ok, terminal} = ForgeImports.transition_run(run, :failed, %{failure_kind: :source_not_found})
  assert terminal.state == :failed
  assert terminal.credential_ciphertext == nil
  assert terminal.credential_nonce == nil
  assert terminal.credential_tag == nil
  assert terminal.credential_key_id == nil
end
```

- [ ] **Step 2: Run the tests before migration**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/import_persistence_test.exs --max-cases 1
```

Expected: FAIL because the import tables do not exist.

- [ ] **Step 3: Add schemas and constraints**

Create the six tables named `github_import_runs`, `github_import_repository_items`, `github_import_attempts`, `github_import_object_mappings`, `github_import_page_checkpoints`, and `github_import_report_entries`. Both run and item tables include `lease_owner`, `lease_expires_at`, and `lock_version`; their schemas expose `lease_update_changeset/2` for `Fornacast.OperationLease`. Use the design's remaining fields and these uniqueness boundaries:

```elixir
create unique_index(:github_import_repository_items, [:import_run_id, :github_repository_id])
create unique_index(:github_import_attempts, [:repository_item_id, :attempt_number])
create unique_index(:github_import_object_mappings, [:hidden_repository_id, :github_repository_id, :object_kind, :github_object_id])
create unique_index(:github_import_page_checkpoints, [:repository_item_id, :resource_kind, :page_key])
create unique_index(:github_import_report_entries, [:import_run_id, :idempotency_key])
```

Keep future hidden/replacement/publication fields nullable but validate consistency once their state uses them. Implement redacted `Inspect` for run/credential-bearing structs. `RunView.from_run/2` contains safe identity/source/destination/state/count fields and never envelope fields.

- [ ] **Step 4: Migrate and verify both state and lease behavior**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix ecto.migrate
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/import_persistence_test.exs apps/fornacast/test/operation_lease_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit import persistence**

```bash
git add apps/fornacast/priv/repo/migrations/20260825000300_create_github_import_domain.exs apps/forge_imports
git commit -m "feat(import): persist durable import plans"
```

### Task 7: Add strict GitHub source parsing and bounded REST transport

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/github/repository_reference.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/client.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/error.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/host_policy.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/pagination.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/request_gate.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/user.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/organization.ex`
- Create: `apps/forge_imports/lib/forge_imports/github/repository.ex`
- Create: `apps/forge_imports/test/github/repository_reference_test.exs`
- Create: `apps/forge_imports/test/github/client_test.exs`

- [ ] **Step 1: Write parser and Req transport tests**

Use `Req.Test` to verify fixed host/version/media/User-Agent headers, no automatic retry/redirect, public-address DNS policy, `Link rel="next"` pagination, serialized calls per credential key, response-size bounds, 401/403/404/429/5xx classification, primary/secondary retry times, malformed JSON, and PAT-free errors.

```elixir
assert {:ok, %{owner: "octocat", repository: "hello-world"}} =
         RepositoryReference.parse("https://github.com/octocat/hello-world.git/")

assert {:error, :invalid_source} =
         RepositoryReference.parse("https://github.com/octocat/hello-world/issues")
```

- [ ] **Step 2: Run the GitHub client tests and verify failure**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github --max-cases 1
```

Expected: FAIL because the GitHub modules do not exist.

- [ ] **Step 3: Implement the deep client interface**

Expose:

```elixir
authenticated_user(pat, opts \\ [])
repository(pat, owner, repository, opts \\ [])
organization(pat, login, opts \\ [])
organization_repositories(pat, login, opts \\ [])
```

Production base URL is always `https://api.github.com`; only tests may inject a Req plug. Set `accept: "application/vnd.github+json"`, `x-github-api-version: "2026-03-10"`, `user-agent: "Fornacast/0.2.0"`, `redirect: false`, and `retry: false`. Follow only validated HTTPS `api.github.com` next links. Return `%GitHub.Error{kind:, retry_at:, detail:}` with bounded classified detail and a redacted `Inspect` implementation.

`HostPolicy` resolves `api.github.com` before a production request and rejects loopback, RFC1918/ULA, link-local, multicast, unspecified, and other non-public IPv4/IPv6 addresses. Tests inject the resolver function; runtime base URL remains non-configurable.

Wrap each request/pagination sequence with `RequestGate.run(gate_key, fun)`, implemented through a bounded `:global.trans` lock. Saved credentials use their credential ID; one-time credentials use the import run ID. Never derive the lock key from PAT bytes.

- [ ] **Step 4: Run client tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github --max-cases 1
```

Expected: all parser/client tests pass.

- [ ] **Step 5: Commit the REST client**

```bash
git add apps/forge_imports/lib/forge_imports/github apps/forge_imports/test/github
git commit -m "feat(import): add bounded GitHub client"
```

### Task 8: Coordinate verified account linking through `ForgeImports`

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/github_accounts.ex`
- Create: `apps/forge_imports/test/github_accounts_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`

- [ ] **Step 1: Write coordinator tests with an injected client**

Test first link, replacement, reverification, returned-ID mismatch, other-user collision masking, expired token invalidation, credential deletion, unlink, and multiple accounts.

```elixir
assert {:ok, %{login: "octocat"}} =
         ForgeImports.link_github_account(actor, "github_pat_secret", request_metadata,
           client: SuccessClient
         )

assert {:error, :identity_mismatch} =
         ForgeImports.replace_github_credential(actor, identity.id, "wrong-token", request_metadata,
           client: DifferentUserClient
         )
```

- [ ] **Step 2: Verify the coordinator APIs are missing**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github_accounts_test.exs --max-cases 1
```

Expected: FAIL with missing public functions.

- [ ] **Step 3: Implement verification-before-persistence**

Delegate these functions from `ForgeImports`:

```elixir
list_github_accounts(actor)
link_github_account(actor, pat, request_metadata, opts \\ [])
reverify_github_account(actor, identity_id, request_metadata, opts \\ [])
replace_github_credential(actor, identity_id, pat, request_metadata, opts \\ [])
delete_github_credential(actor, identity_id, request_metadata)
unlink_github_account(actor, identity_id, request_metadata)
```

Every PAT write first calls `authenticated_user/2`. Replacement/reverification requires the returned numeric ID to equal the selected identity. Convert external errors to stable domain atoms before calling `ForgeAccounts`.

- [ ] **Step 4: Run coordinator and account tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github_accounts_test.exs apps/forge_accounts/test/github_accounts_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit account coordination**

```bash
git add apps/forge_imports/lib/forge_imports.ex apps/forge_imports/lib/forge_imports/github_accounts.ex apps/forge_imports/test/github_accounts_test.exs
git commit -m "feat(import): verify GitHub account links"
```

### Task 9: Build side-effect-free repository and organization discovery

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/discovery.ex`
- Create: `apps/forge_imports/lib/forge_imports/destination.ex`
- Create: `apps/forge_imports/lib/forge_imports/discovery_worker.ex`
- Create: `apps/forge_imports/lib/forge_imports/reconciler.ex`
- Create: `apps/forge_imports/lib/forge_imports/recovery_supervisor.ex`
- Create: `apps/forge_imports/test/discovery_test.exs`
- Create: `apps/forge_imports/test/discovery_recovery_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/application.ex`

- [ ] **Step 1: Write discovery-plan tests**

Cover saved and one-time credentials, exactly one repository item, paginated organization repositories, all-selected default, destination ownership, reserved/invalid slugs, normalized collisions, internal-to-private warning, fork/archive/release unsupported category warnings without release enumeration, foreign-run masking, failed-discovery envelope cleanup, worker crash/restart recovery, and proof that no organization/repository/storage row is created.

```elixir
assert {:ok, %ForgeImports.RunView{state: :awaiting_resolution, repositories: [item]}} =
         ForgeImports.create_repository_discovery(actor, attrs, request_metadata,
           dispatch: :inline,
           client: RepositoryClient
         )

assert item.selected
assert item.destination_visibility == :private
assert Repo.aggregate(ForgeRepos.Repository, :count) == repository_count_before
```

- [ ] **Step 2: Run the discovery test and verify failure**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/discovery_test.exs --max-cases 1
```

Expected: FAIL with missing discovery APIs.

- [ ] **Step 3: Implement durable discovery**

Expose:

```elixir
create_repository_discovery(actor, attrs, request_metadata, opts \\ [])
create_organization_discovery(actor, attrs, request_metadata, opts \\ [])
get_run(actor, run_id)
update_organization_destination(actor, run_id, destination)
update_repository_selection(actor, run_id, selected_github_repository_ids)
```

Verify a one-time PAT through `authenticated_user/2`, observe its GitHub identity without linking it or creating a saved credential, then allocate/encrypt the envelope only after the run ID exists. Commit the `discovering` run, dispatch a supervised worker, and return the safe run view immediately. Persist only allowlisted source metadata. Commit items, `awaiting_resolution`, and a sanitized `github_import.discovered` audit in one transaction after all discovery pages succeed. On failure, transition to `failed`, record a bounded report entry/audit, and clear one-time fields atomically.

`RecoverySupervisor` owns `ForgeImports.TaskSupervisor` and `ForgeImports.Reconciler` with `:one_for_all`. The reconciler starts one `Task.Supervisor.async_nolink` scan at startup and on a bounded interval; in this milestone it claims only `discovering` runs through `Fornacast.OperationLease` and invokes `DiscoveryWorker`. A worker crash leaves durable `discovering` state, which the next scan reclaims. `dispatch: :inline` is test-only.

- [ ] **Step 4: Run discovery/persistence tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/discovery_test.exs apps/forge_imports/test/discovery_recovery_test.exs apps/forge_imports/test/import_persistence_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit discovery**

```bash
git add apps/forge_imports
git commit -m "feat(import): discover GitHub migration plans"
```

### Task 10: Add GitHub account settings in HEEx

**Files:**

- Create: `apps/fornacast_web/lib/fornacast_web/controllers/github_settings_controller.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/github_settings_html.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/github_settings_html/index.html.heex`
- Create: `apps/fornacast_web/test/github_settings_controller_test.exs`
- Create: `apps/fornacast_web/test/github_settings_html_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/api_key_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex`

- [ ] **Step 1: Write authentication, mutation, and secret-leak tests**

Test GET, link, reverify, replace, delete PAT, unlink, multiple rows, CSRF, invalid credential, unavailable vault, disabled user, and no PAT in body/session/redirect/flash/log.

```elixir
conn = post(authenticated_conn(actor), "/settings/github", %{
  "github_account" => %{"pat" => "github_pat_secret"}
})

refute conn.resp_body =~ "github_pat_secret"
refute inspect(get_session(conn)) =~ "github_pat_secret"
```

- [ ] **Step 2: Run web tests before routes exist**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/github_settings_controller_test.exs apps/fornacast_web/test/github_settings_html_test.exs --max-cases 1
```

Expected: FAIL with no route/controller.

- [ ] **Step 3: Add owner-scoped routes/controller/templates**

Add:

```elixir
get "/settings/github", GitHubSettingsController, :index
post "/settings/github", GitHubSettingsController, :create
post "/settings/github/:identity_id/reverify", GitHubSettingsController, :reverify
put "/settings/github/:identity_id/credential", GitHubSettingsController, :replace
delete "/settings/github/:identity_id/credential", GitHubSettingsController, :delete_credential
delete "/settings/github/:identity_id", GitHubSettingsController, :unlink
```

Use `conn.private[:forge_imports] || ForgeImports` for controller tests. Every response uses `cache-control: private, no-store`; PAT fields are never assigned back to HEEx. Use PhoenixDuskmoon components and extend existing settings navigation with GitHub.

- [ ] **Step 4: Run settings tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/github_settings_controller_test.exs apps/fornacast_web/test/github_settings_html_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit settings UI**

```bash
git add apps/fornacast_web
git commit -m "feat(web): manage linked GitHub accounts"
```

### Task 11: Replace the disabled placeholder with discovery pages

**Files:**

- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_controller.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_html.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/repository.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/organization.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/show.html.heex`
- Create: `apps/fornacast_web/test/import_controller_test.exs`
- Create: `apps/fornacast_web/test/import_html_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/html.ex`
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Write discovery-page tests**

Cover authenticated forms, saved/one-time choice, malformed input, repository/org discovery, selection updates, new/existing owned organization destination, reserved destination, foreign-run 404, no-JavaScript forms, safe warnings/conflicts, and no start/cancel/retry controls in this milestone.

- [ ] **Step 2: Run the focused web tests and verify failure**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/import_controller_test.exs apps/fornacast_web/test/import_html_test.exs --max-cases 1
```

Expected: FAIL because `/organizations/import` and discovery POST routes are absent.

- [ ] **Step 3: Add the routes and controller contract**

```elixir
get "/repos/import", ImportController, :repository_new
post "/repos/import/discover", ImportController, :repository_discover
get "/organizations/import", ImportController, :organization_new
post "/organizations/import/discover", ImportController, :organization_discover
get "/imports/:id", ImportController, :show
patch "/imports/:id/destination", ImportController, :destination
patch "/imports/:id/selection", ImportController, :selection
```

Remove `RepositoryController.import_new/2`. Render only `%RunView{}` data, use `private, no-store`, include all-selected checkboxes and collision/warning rows, and add the organization-import create-menu link. Keep start/cancel/retry absent until later plans implement their domain operations.

- [ ] **Step 4: Run discovery UI tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/import_controller_test.exs apps/fornacast_web/test/import_html_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit discovery UI**

```bash
git add apps/fornacast_web
git commit -m "feat(web): discover GitHub imports"
```

### Task 12: Verify milestone 1 on both database adapters

**Files:**

- Modify only files required to fix failures caused by Tasks 1–11.

- [ ] **Step 1: Run formatting and warnings-as-errors**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix format --check-formatted
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix compile --warnings-as-errors
```

Expected: both commands exit 0.

- [ ] **Step 2: Run the complete focused Turso milestone suite serially**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast/test/fornacast_test.exs apps/forge_accounts/test apps/forge_imports/test apps/fornacast_web/test/github_settings_controller_test.exs apps/fornacast_web/test/github_settings_html_test.exs apps/fornacast_web/test/import_controller_test.exs apps/fornacast_web/test/import_html_test.exs --max-cases 1
```

Expected: 0 failures.

- [ ] **Step 3: Recompile and run the same persistence/domain surface on PostgreSQL**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast/test/fornacast_test.exs apps/forge_accounts/test apps/forge_imports/test --max-cases 1
```

Expected: 0 failures using the configured PostgreSQL test database.

- [ ] **Step 4: Prove the milestone boundary**

```bash
rg -n "GitCore.Remote|start_import|publish_repository" apps/forge_imports apps/fornacast_web
```

Expected: no production implementation of clone, start, or publication exists; discovery stops at `awaiting_resolution`.

- [ ] **Step 5: Commit only verification-driven corrections**

```bash
git status --short
git diff --check
git add apps config mix.exs mix.lock README.md .env.example
git commit -m "test(import): verify GitHub import foundation"
```

If `git status --short` is clean after verification, do not create an empty commit.
