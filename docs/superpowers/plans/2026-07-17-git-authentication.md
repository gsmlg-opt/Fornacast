# Git Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept standard OpenSSH RSA keys and provide GitHub-style personal API keys for authenticated smart HTTP clone, fetch, and push.

**Architecture:** Keep SSH key parsing in `ForgeAccounts.SSHKey`, add a focused `ForgeAccounts.APIKey` credential schema with public lifecycle functions in `ForgeAccounts`, and make `FornacastWeb.GitHTTPController` authenticate Basic credentials before applying existing repository authorization. Extend the existing protocol-v0 controller with `GitTransport.ReceivePack`, sharing push bookkeeping with SSH rather than introducing `git http-backend`.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, Ecto with PostgreSQL/Turso migrations, Erlang/OTP SSH, Git smart HTTP protocol v0, ExUnit.

---

## File map

- `apps/forge_accounts/lib/forge_accounts/ssh_key.ex`: validate standard OpenSSH RSA key lines.
- `apps/forge_accounts/lib/forge_accounts/api_key.ex`: API-key schema, validation, secret generation, hashing, and constant-time verification.
- `apps/forge_accounts/lib/forge_accounts.ex`: user-owned API-key lifecycle and scoped authentication boundary.
- `apps/fornacast/priv/repo/migrations/20260717000100_create_api_keys.exs`: portable API-key persistence and indexes.
- `apps/fornacast_web/lib/fornacast_web/controllers/api_key_controller.ex`: settings UI lifecycle and one-time secret display.
- `apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex`: human-readable key validation errors.
- `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`: scoped API-key authentication plus upload-pack/receive-pack endpoints.
- `apps/fornacast_web/lib/fornacast_web/router.ex`: settings and smart HTTP routes.
- `apps/git_transport/lib/git_transport/receive_pack.ex`: shared successful-push bookkeeping used by SSH and HTTP.
- `apps/git_transport/lib/git_transport/channel.ex`: delegate SSH push bookkeeping to `ReceivePack`.
- `apps/forge_repos/lib/forge_repos.ex`: HTTP clone URL builder alongside the SSH URL builder.
- `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`: render SSH and HTTP clone instructions.
- Existing focused test files validate each public behavior.

### Task 1: Standard OpenSSH RSA keys and readable validation

**Files:**
- Modify: `apps/forge_accounts/lib/forge_accounts/ssh_key.ex`
- Test: `apps/forge_accounts/test/forge_accounts_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`
- Test: `apps/git_transport/test/git_transport_test.exs`

- [ ] **Step 1: Write failing account and web tests for the exact RSA format**

Add a real RSA fixture beginning with `ssh-rsa` and ending in a comment, then assert:

```elixir
test "ssh key changeset accepts a standard OpenSSH RSA public key" do
  changeset =
    SSHKey.changeset(%SSHKey{user_id: 1}, %{
      title: "servers",
      public_key: @ssh_rsa_public_key
    })

  assert changeset.valid?
  assert "SHA256:" <> _ = Ecto.Changeset.get_change(changeset, :fingerprint_sha256)
end
```

Change the old unsupported-algorithm test to use an actually unsupported key type. Add a controller test asserting an invalid key response contains a human sentence and does not contain `public_key: {` or validation metadata.

- [ ] **Step 2: Run the tests and verify the intended failures**

Run:

```bash
mix test apps/forge_accounts/test/forge_accounts_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: RSA validation fails with the current accepted-algorithm message, and the web response exposes `inspect(changeset.errors)`.

- [ ] **Step 3: Accept the standard key type and render field errors**

Set the accepted types to standard OpenSSH key formats:

```elixir
@accepted_algorithms ~w(ssh-ed25519 ssh-rsa)
```

Keep decoding through `:ssh_file.decode/2` and fingerprinting the decoded blob. Update the unsupported message to `must use ssh-ed25519 or ssh-rsa`.

In `SSHKeyController`, turn changeset errors into escaped sentences using `Ecto.Changeset.traverse_errors/2`, replacing `%{count: count}` placeholders, and render them through `error_panel/1` rather than inspecting internal tuples.

- [ ] **Step 4: Prove a real client uses the stored ssh-rsa key**

Change the RSA helper in `git_transport_test.exs` to return the normal `ssh-rsa` line instead of replacing its prefix with `rsa-sha2-256`. Keep the current OpenSSH client integration tests; add `-o PubkeyAcceptedAlgorithms=rsa-sha2-512,rsa-sha2-256` so the test explicitly excludes the SHA-1 signature algorithm.

- [ ] **Step 5: Run focused tests and commit**

Run:

```bash
mix test apps/forge_accounts/test/forge_accounts_test.exs apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: all three suites pass.

Commit:

```bash
git add apps/forge_accounts apps/git_transport/test apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "fix(auth): accept standard OpenSSH RSA keys"
```

### Task 2: Personal API-key domain model

**Files:**
- Create: `apps/fornacast/priv/repo/migrations/20260717000100_create_api_keys.exs`
- Create: `apps/forge_accounts/lib/forge_accounts/api_key.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`
- Test: `apps/forge_accounts/test/forge_accounts_test.exs`

- [ ] **Step 1: Write failing lifecycle and authentication tests**

Cover creation, one-time raw secret return, hashed persistence, list ownership, read/write scopes, last-used timestamp, expiration, revocation, inactive users, wrong usernames, and invalid tokens. Use this public contract:

```elixir
assert {:ok, api_key, "fc_pat_" <> _ = secret} =
         ForgeAccounts.create_api_key(user, %{
           "name" => "workstation",
           "scopes" => ["repo:read", "repo:write"]
         })

refute api_key.token_hash == secret
assert {:ok, ^user, authenticated_key} =
         ForgeAccounts.authenticate_api_key("alice", secret, "repo:write")
assert authenticated_key.id == api_key.id
assert {:error, :insufficient_scope} =
         ForgeAccounts.authenticate_api_key("alice", read_secret, "repo:write")
```

- [ ] **Step 2: Run the account tests and verify missing API-key functions fail**

Run:

```bash
mix test apps/forge_accounts/test/forge_accounts_test.exs --max-cases 1
```

Expected: compile/test failures identify the missing `APIKey` module and lifecycle functions.

- [ ] **Step 3: Add the portable migration**

Create `api_keys` with `user_id`, `name`, `token_prefix`, `token_hash`, `scopes` as a map, `expires_at`, `last_used_at`, `revoked_at`, and UTC timestamps. Add indexes on `user_id`, a unique index on `token_hash`, and an index on `token_prefix`.

- [ ] **Step 4: Implement the focused API-key schema**

Define `ForgeAccounts.APIKey` with allowed scopes `repo:read` and `repo:write`. Generate secrets as:

```elixir
def generate_secret do
  secret = "fc_pat_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  {secret, String.slice(secret, 0, 15), hash(secret)}
end

def hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
```

Normalize the input scope list into a map such as `%{"repo:read" => true}`; reject empty or unknown scopes. Verify hashes with `Plug.Crypto.secure_compare/2`.

- [ ] **Step 5: Implement user-owned lifecycle functions**

Add:

```elixir
create_api_key(%User{}, attrs)
list_user_api_keys(%User{})
revoke_api_key(%User{}, key_id)
authenticate_api_key(username, secret, required_scope)
```

Authentication must require an active user, a matching non-revoked key, a non-expired key, and the requested scope. Treat `repo:write` as satisfying `repo:read`, update `last_used_at` only after successful authentication, and return stable errors without revealing whether a username or key exists.

- [ ] **Step 6: Migrate the test database, pass tests, and commit**

Run:

```bash
MIX_ENV=test mix ecto.migrate
mix test apps/forge_accounts/test/forge_accounts_test.exs --max-cases 1
```

Expected: account tests pass.

Commit:

```bash
git add apps/fornacast/priv/repo/migrations/20260717000100_create_api_keys.exs apps/forge_accounts
git commit -m "feat(auth): add personal API keys"
```

### Task 3: API-key settings UI

**Files:**
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/api_key_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/html.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Write failing settings tests**

Test that an authenticated user can open `/settings/api-keys`, create a named key with checked read/write scopes, see the `fc_pat_...` secret once in the POST response, revisit the list without seeing the secret, and revoke only their own key. Assert anonymous requests redirect through the existing authenticated pipeline.

- [ ] **Step 2: Run the web tests and verify routes are missing**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: the API-key settings routes return 404.

- [ ] **Step 3: Add authenticated routes and controller**

Add:

```elixir
get "/settings/api-keys", APIKeyController, :index
post "/settings/api-keys", APIKeyController, :create
delete "/settings/api-keys/:id", APIKeyController, :delete
```

Render a name field, read/write scope checkboxes, optional `datetime-local` expiration, existing key metadata, and revoke buttons. On successful creation, render the raw secret once in a clearly labeled panel with a warning that it cannot be recovered. Never place it in session flash, logs, redirects, or persisted HTML.

- [ ] **Step 4: Add settings navigation and readable validation**

Add an API-key settings link next to SSH-key settings. Render schema validation as escaped field messages, using the same error formatting introduced for SSH keys.

- [ ] **Step 5: Run tests and commit**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: web tests pass.

Commit:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/api_key_controller.ex apps/fornacast_web/lib/fornacast_web/router.ex apps/fornacast_web/lib/fornacast_web/html.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(settings): manage personal API keys"
```

### Task 4: API-key authentication for HTTP clone and fetch

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Replace the private-clone password test with API-key behavior tests**

Create a `repo:read` key and verify a real Git private clone succeeds when credentials are supplied through an isolated test credential helper or URL. Add request-level assertions that the account password, invalid key, revoked key, expired key, and a valid key belonging to another username all receive the Basic `401` challenge. Keep the public anonymous clone test.

- [ ] **Step 2: Run the web tests and verify password/API-key mismatch**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: API-key clone fails because `authenticate_basic/1` still calls `authenticate_password/2`.

- [ ] **Step 3: Authenticate the required read scope**

Decode Basic auth into username and key, then call:

```elixir
ForgeAccounts.authenticate_api_key(username, secret, "repo:read")
```

For public repositories, allow a missing Authorization header but validate any header that is provided. For private repositories, require an authenticated actor before `Fornacast.Access.authorize/3`. Normalize invalid, expired, revoked, and insufficient-scope failures to the Git Basic challenge.

- [ ] **Step 4: Run tests and commit**

Run:

```bash
mix test apps/forge_accounts/test/forge_accounts_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: account and web suites pass.

Commit:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(git-http): authenticate clone with API keys"
```

### Task 5: Authenticated smart HTTP push

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`
- Modify: `apps/git_transport/lib/git_transport/receive_pack.ex`
- Modify: `apps/git_transport/lib/git_transport/channel.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`
- Test: `apps/git_transport/test/git_transport_test.exs`

- [ ] **Step 1: Write failing real-Git push tests**

Start the test Bandit endpoint, create a repository and a write-scoped key, initialize a local commit, and run:

```elixir
git(["push", "http://alice:#{secret}@127.0.0.1:#{port}/alice/demo.git", "main"])
```

Assert the push succeeds, the branch exists, `last_pushed_at` is set, and one `repository.pushed` audit event names the actor and refs. Add failures for missing auth, account password, read-only key, revoked key, and a valid write key for a user without repository write access.

- [ ] **Step 2: Run the web tests and verify receive-pack is unsupported**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: Git reports that `git-receive-pack` advertisement or POST is unavailable.

- [ ] **Step 3: Add receive-pack routes and content types**

Add the POST route:

```elixir
post "/:owner/:repo_dot_git/git-receive-pack", GitHTTPController, :receive_pack
```

Extend `info_refs/2` for `service=git-receive-pack`. Use content types `application/x-git-receive-pack-advertisement` and `application/x-git-receive-pack-result`.

- [ ] **Step 4: Require write scope and parse the receive body**

Require `username:api_key`, authenticate `repo:write`, resolve the repository, and authorize `:repository_write`. Read the complete request body, feed command packets and pack bytes through `GitTransport.ReceivePack.parse_request_data/2`, then call `GitTransport.ReceivePack.response/3` and send its result.

- [ ] **Step 5: Share successful push bookkeeping**

Move the successful-status check, `ForgeRepos.mark_pushed/1`, and `Fornacast.Audit.record/5` into a public `GitTransport.ReceivePack.record_success/3`. Call it from both the SSH channel and HTTP controller after `response/3`. Keep failures non-fatal to the already-completed Git update and do not include credentials in metadata.

- [ ] **Step 6: Run transport/web tests and commit**

Run:

```bash
mix test apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: real SSH and HTTP push tests pass.

Commit:

```bash
git add apps/git_transport apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex apps/fornacast_web/lib/fornacast_web/router.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(git-http): support authenticated push"
```

### Task 6: HTTP clone instructions and final scoped verification

**Files:**
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Test: `apps/forge_repos/test/forge_repos_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Write failing clone-instruction tests**

Assert `ForgeRepos.http_clone_url/2` preserves `/:owner/:repo.git`, uses the configured endpoint scheme/host/port, and repository pages show both SSH and HTTP URLs plus text explaining that the password prompt expects a personal API key.

- [ ] **Step 2: Run focused tests and verify the HTTP helper is missing**

Run:

```bash
mix test apps/forge_repos/test/forge_repos_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
```

Expected: missing helper or missing HTTP clone instructions fail.

- [ ] **Step 3: Implement the URL helper and repository instructions**

Build the HTTP URL from the request endpoint and resolved owner slug without embedding credentials. Render copyable SSH and HTTP commands, and link the API-key settings page from the HTTP explanation.

- [ ] **Step 4: Run formatting and all in-scope tests**

Run:

```bash
mix format --check-formatted
mix test apps/forge_accounts/test/forge_accounts_test.exs apps/forge_repos/test/forge_repos_test.exs apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/fornacast_web_test.exs --max-cases 1
git diff --check
```

Expected: formatting succeeds, all scoped tests pass, and the diff has no whitespace errors.

- [ ] **Step 5: Commit the repository instructions**

```bash
git add apps/forge_repos apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(repos): show HTTP clone instructions"
```

- [ ] **Step 6: Confirm scope and branch state**

Run:

```bash
git status --short --branch
git log --oneline main..HEAD
```

Expected: only the unrelated ignored build/dependency directories are untracked, implementation files are clean, and the branch contains the planned logical commits. Do not merge or push unless requested.
