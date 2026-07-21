# GitHub-Compatible Issues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub-compatible repository issues and issue comments, including one atomic number sequence shared with pull requests, normalized labels and assignees, and the first-release permission and filtering contract.

**Architecture:** Add a `forge_issues` umbrella application that owns issue identities, comments, repository labels, assignee relationships, and the repository-local number allocator. Keep cross-context references as integer IDs and resolve accounts and repositories through their public contexts; expose composable `Ecto.Multi` functions so the later pull-request slice can insert and update its canonical issue row inside one outer transaction. Extend the separate API application with thin controllers, explicit versioned validators and serializers, and the two pinned pruned OpenAPI artifacts.

**Tech Stack:** Elixir 1.20, Ecto 3.14 with Turso and PostgreSQL, Phoenix 1.8, Bandit, the checked-in GHES 3.21 OpenAPI contract, and ExUnit.

---

**Approved specification:** `docs/superpowers/specs/2026-07-21-github-compatible-api-design.md`

**Depends on:** `2026-07-21-github-api-foundation.md` and `2026-07-21-github-api-git-data.md` are complete.

## Scope and execution guardrails

- Implement repository issues, issue comments, default repository labels, issue-label assignments, issue assignees, and the shared issue/pull number sequence.
- Keep issue title, body, author, number, state, state reason, labels, assignees, comments, and shared timestamps canonical in `ForgeIssues.Issue`. The pull slice stores none of those values again.
- Keep `forge_issues` dependent on `fornacast`, `forge_accounts`, `forge_repos`, and `ecto` only. Do not add a dependency on `forge_pulls`, `git_core`, `fornacast_api`, or `fornacast_web`.
- Use integer IDs and explicit queries across context boundaries. Do not add `belongs_to`, `has_many`, or `many_to_many` associations to schemas from another context.
- Do not use a database sequence, `FOR UPDATE`, `SKIP LOCKED`, adapter-specific `RETURNING`, or an application process for number allocation. The allocator is an ordinary SQL row updated inside the caller's transaction.
- `ForgeIssues.insert_numbered_identity/6` and `ForgeIssues.update_identity/5` append operations to a caller-owned `Ecto.Multi` and return it. They never call `Repo.transaction/1`.
- Use the foundation function `Fornacast.Audit.record_multi(multi, key, actor, action, target_type, target_id, metadata, opts \\ [])` for audit writes. Do not introduce another audit helper.
- Resolve and authorize the repository before loading an issue, comment, label, assignee, or serialized database object.
- `has_issues: false` excludes ordinary rows from the issue list while preserving a `200` list of pull-backed rows. It returns the approved `410` for ordinary create/detail/update/comment operations and does not prevent pull-backed identity creation, detail reads, or comments.
- Run Turso-backed database tests serially with `--max-cases 1`. Format only files changed by this plan.

## Public domain contract

`ForgeIssues` returns tagged results and accepts domain actors that were authenticated by the API boundary:

~~~elixir
@type error_reason ::
        :not_found
        | :forbidden
        | :issues_disabled
        | {:unavailable, atom()}
        | {:validation, [validation_error()]}

@type validation_error :: %{
        required(:resource) => String.t(),
        required(:field) => String.t(),
        required(:code) =>
          :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
        optional(:message) => String.t()
      }

@spec list(ForgeAccounts.User.t() | nil, String.t(), String.t(), map()) ::
        {:ok, Fornacast.Page.t(ForgeIssues.Issue.t())} | {:error, error_reason()}
@spec get(ForgeAccounts.User.t() | nil, String.t(), String.t(), pos_integer()) ::
        {:ok, ForgeIssues.Issue.t()} | {:error, error_reason()}
@spec create(ForgeAccounts.User.t(), String.t(), String.t(), map(), map()) ::
        {:ok, ForgeIssues.Issue.t()} | {:error, error_reason()}
@spec update(
        ForgeAccounts.User.t(),
        String.t(),
        String.t(),
        pos_integer(),
        map(),
        map()
      ) :: {:ok, ForgeIssues.Issue.t()} | {:error, error_reason()}

@spec list_comments(
        ForgeAccounts.User.t() | nil,
        String.t(),
        String.t(),
        pos_integer(),
        map()
      ) :: {:ok, Fornacast.Page.t(ForgeIssues.Comment.t())} | {:error, error_reason()}
@spec create_comment(
        ForgeAccounts.User.t(),
        String.t(),
        String.t(),
        pos_integer(),
        map(),
        map()
      ) :: {:ok, ForgeIssues.Comment.t()} | {:error, error_reason()}
@spec update_comment(
        ForgeAccounts.User.t(),
        String.t(),
        String.t(),
        pos_integer(),
        map(),
        map()
      ) :: {:ok, ForgeIssues.Comment.t()} | {:error, error_reason()}
@spec delete_comment(
        ForgeAccounts.User.t(),
        String.t(),
        String.t(),
        pos_integer(),
        map()
      ) :: :ok | {:error, error_reason()}

@spec insert_numbered_identity(
        Ecto.Multi.t(),
        Ecto.Multi.name(),
        ForgeRepos.Repository.t(),
        ForgeAccounts.User.t(),
        :issue | :pull_request,
        map()
      ) :: Ecto.Multi.t()
@spec update_identity(
        Ecto.Multi.t(),
        Ecto.Multi.name(),
        ForgeIssues.Issue.t(),
        ForgeAccounts.User.t(),
        map()
      ) :: Ecto.Multi.t()
~~~

HTTP-facing context functions accept owner/repository slugs and call `ForgeRepos.fetch_authorized_repository/4` internally before querying issue tables. Mutation functions receive the safe map from `FornacastAPI.Plugs.RequestContext.metadata/1` with `request_id`, `api_version`, `ip_address`, `user_agent`, and `token_id`. PAT scope enforcement stays in `fornacast_api`; repository role and resource-author rules stay in `forge_issues`.

## File map

### Umbrella application and persistence

- Create `apps/forge_issues/mix.exs`.
- Create `apps/forge_issues/lib/forge_issues/application.ex`.
- Create `apps/forge_issues/lib/forge_issues.ex`.
- Create `apps/forge_issues/lib/forge_issues/number_sequence.ex`.
- Create `apps/forge_issues/lib/forge_issues/issue.ex`.
- Create `apps/forge_issues/lib/forge_issues/comment.ex`.
- Create `apps/forge_issues/lib/forge_issues/label.ex`.
- Create `apps/forge_issues/lib/forge_issues/issue_label.ex`.
- Create `apps/forge_issues/lib/forge_issues/issue_assignee.ex`.
- Create `apps/forge_issues/lib/forge_issues/default_labels.ex`.
- Create `apps/forge_issues/test/test_helper.exs`.
- Create `apps/forge_issues/test/support/fixtures.exs`.
- Create `apps/forge_issues/test/forge_issues_test.exs`.
- Create `apps/forge_issues/test/number_allocator_test.exs`.
- Create `apps/fornacast/priv/repo/migrations/20260721000300_create_issue_domain.exs`.
- Modify `mix.exs` and `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex` to start `forge_issues`.
- Modify `apps/fornacast_web/test/fornacast_run_task_test.exs` to lock the service list.

### API contract and HTTP boundary

- Modify `apps/fornacast_api/mix.exs`.
- Modify `apps/fornacast_api/lib/fornacast_api/router.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/error.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/url.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/request_validator.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializer.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/issue_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/issue_comment_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/issue_contract.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/issue.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/issue.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/issue.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/issue_comment.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/issue.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/issue_comment.ex`.
- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`.
- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`.
- Modify `apps/fornacast_api/priv/openapi/fornacast-overlay.json`.
- Create `apps/fornacast_api/test/issue_controller_test.exs`.
- Create `apps/fornacast_api/test/issue_contract_test.exs`.
- Modify `apps/fornacast_api/test/openapi_contract_test.exs`.
- Create `apps/fornacast_api/test/issue_workflow_test.exs`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/issues/pull-issue.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-comment.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-list.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-comment-list.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/issues/pull-issue.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-comment.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-list.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-comment-list.json`.

### Task 1: Scaffold the issue application and portable tables

**Files:**

- Create: `apps/forge_issues/mix.exs`
- Create: `apps/forge_issues/lib/forge_issues/application.ex`
- Create: `apps/forge_issues/test/test_helper.exs`
- Create: `apps/forge_issues/test/support/fixtures.exs`
- Create: `apps/fornacast/priv/repo/migrations/20260721000300_create_issue_domain.exs`
- Modify: `mix.exs`
- Modify: `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`
- Modify: `apps/fornacast_web/test/fornacast_run_task_test.exs`

- [ ] **Step 1: Write the failing umbrella service test**

Change the run-task expectation so the complete ordered service list is:

~~~elixir
[
  :fornacast,
  :forge_accounts,
  :forge_repos,
  :git_core,
  :git_transport,
  :forge_issues,
  :fornacast_api,
  :fornacast_web
]
~~~

Also assert the root release configuration contains `forge_issues: :permanent`.

- [ ] **Step 2: Run the service test and verify the missing application**

Run:

~~~bash
mix test apps/fornacast_web/test/fornacast_run_task_test.exs
~~~

Expected: FAIL because `:forge_issues` is absent from the development service list and root release.

- [ ] **Step 3: Add the application without a stateless worker**

Create `apps/forge_issues/mix.exs`:

~~~elixir
defmodule ForgeIssues.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_issues,
      version: "0.1.0",
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
    [
      extra_applications: [:logger],
      mod: {ForgeIssues.Application, []}
    ]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:forge_repos, in_umbrella: true},
      {:ecto, "~> 3.14"}
    ]
  end
end
~~~

Create an empty supervisor because this slice has no runtime state:

~~~elixir
defmodule ForgeIssues.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: ForgeIssues.Supervisor)
  end
end
~~~

Insert `forge_issues: :permanent` after `forge_repos` in the root release and insert `:forge_issues` before `:fornacast_api` in `Mix.Tasks.Fornacast.Run`.

- [ ] **Step 4: Add the complete adapter-neutral migration**

Create the migration with these tables and constraints:

~~~elixir
defmodule Fornacast.Repo.Migrations.CreateIssueDomain do
  use Ecto.Migration

  def change do
    create table(:repository_number_sequences, primary_key: false) do
      add(:repository_id, references(:repositories, on_delete: :delete_all),
        null: false,
        primary_key: true
      )
      add(:next_number, :bigint,
        null: false,
        default: 1,
        check: [name: "number_sequence_positive", expr: "next_number > 0"]
      )
      timestamps(type: :utc_datetime)
    end

    create table(:issues) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:number, :bigint, null: false)
      add(:kind, :string,
        null: false,
        check: [name: "issues_kind_check", expr: "kind in ('issue', 'pull_request')"]
      )
      add(:title, :string, null: false)
      add(:body, :text)
      add(:state, :string,
        null: false,
        default: "open",
        check: [name: "issues_state_check", expr: "state in ('open', 'closed')"]
      )
      add(:state_reason, :string,
        check: [
          name: "issues_state_reason_check",
          expr: "state_reason is null or state_reason in ('completed', 'not_planned', 'reopened')"
        ]
      )
      add(:author_user_id, references(:users, on_delete: :restrict), null: false)
      add(:closed_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:issues, [:repository_id, :number]))
    create(index(:issues, [:repository_id, :state, :updated_at, :id]))
    create(index(:issues, [:author_user_id]))

    create table(:issue_comments) do
      add(:issue_id, references(:issues, on_delete: :delete_all), null: false)
      add(:author_user_id, references(:users, on_delete: :restrict), null: false)
      add(:body, :text, null: false)
      timestamps(type: :utc_datetime)
    end

    create(index(:issue_comments, [:issue_id, :inserted_at, :id]))
    create(index(:issue_comments, [:author_user_id]))

    create table(:repository_labels) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:normalized_name, :string, null: false)
      add(:color, :string, null: false)
      add(:description, :text)
      add(:default, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:repository_labels, [:repository_id, :normalized_name]))
    create(index(:repository_labels, [:repository_id, :name]))

    create table(:issue_labels) do
      add(:issue_id, references(:issues, on_delete: :delete_all), null: false)
      add(:label_id, references(:repository_labels, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:issue_labels, [:issue_id, :label_id]))
    create(index(:issue_labels, [:label_id]))

    create table(:issue_assignees) do
      add(:issue_id, references(:issues, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:issue_assignees, [:issue_id, :user_id]))
    create(index(:issue_assignees, [:user_id]))

    create_postgres_check(:repository_number_sequences, :number_sequence_positive,
      "next_number > 0"
    )
    create_postgres_check(:issues, :issues_kind_check,
      "kind in ('issue', 'pull_request')"
    )
    create_postgres_check(:issues, :issues_state_check, "state in ('open', 'closed')")
    create_postgres_check(:issues, :issues_state_reason_check,
      "state_reason is null or state_reason in ('completed', 'not_planned', 'reopened')"
    )
  end

  defp create_postgres_check(table, name, expression) do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(constraint(table, name, check: expression))
    end
  end
end
~~~

Keep `size`-like counters as `:bigint` here and in later slices; the API's positive integer contract is wider than PostgreSQL `integer`.

- [ ] **Step 5: Add deterministic test setup**

Create `apps/forge_issues/test/test_helper.exs`:

~~~elixir
ExUnit.start()
Code.require_file("support/fixtures.exs", __DIR__)

if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
  Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, :manual)
end
~~~

In `fixtures.exs`, expose `reset_database!/0`, `user_fixture/2`, and `repository_fixture/2`. For PostgreSQL, checkout the Sandbox once per test process. For Turso, delete in this exact child-first order:

~~~elixir
[
  "issue_assignees",
  "issue_labels",
  "issue_comments",
  "issues",
  "repository_labels",
  "repository_number_sequences",
  "audit_events",
  "repository_collaborators",
  "repositories",
  "organization_members",
  "api_keys",
  "ssh_keys",
  "users"
]
~~~

Each test setup calls `reset_database!/0` and registers an `on_exit/1` Turso cleanup so this new app never leaves foreign-key rows for another umbrella application's tests.

- [ ] **Step 6: Migrate, rerun the service test, and commit**

Run:

~~~bash
MIX_ENV=test mix ecto.migrate
mix test apps/fornacast_web/test/fornacast_run_task_test.exs
~~~

Expected: migration succeeds on the configured adapter and the service test passes.

Commit:

~~~bash
git add apps/forge_issues/mix.exs apps/forge_issues/lib/forge_issues/application.ex apps/forge_issues/test/test_helper.exs apps/forge_issues/test/support/fixtures.exs apps/fornacast/priv/repo/migrations/20260721000300_create_issue_domain.exs mix.exs apps/fornacast_web/lib/mix/tasks/fornacast.run.ex apps/fornacast_web/test/fornacast_run_task_test.exs
git commit -m "feat(issues): add issue domain persistence"
~~~

### Task 2: Define canonical issue schemas and the shared number allocator

**Files:**

- Create: `apps/forge_issues/lib/forge_issues/number_sequence.ex`
- Create: `apps/forge_issues/lib/forge_issues/issue.ex`
- Create: `apps/forge_issues/lib/forge_issues/comment.ex`
- Create: `apps/forge_issues/lib/forge_issues/label.ex`
- Create: `apps/forge_issues/lib/forge_issues/issue_label.ex`
- Create: `apps/forge_issues/lib/forge_issues/issue_assignee.ex`
- Create: `apps/forge_issues/lib/forge_issues.ex`
- Create: `apps/forge_issues/test/number_allocator_test.exs`

- [ ] **Step 1: Write failing allocator and canonical-identity tests**

Add tests that call the public composable function directly:

~~~elixir
multi =
  Ecto.Multi.new()
  |> ForgeIssues.insert_numbered_identity(
    :issue,
    repository,
    actor,
    :issue,
    %{title: "First issue", body: "body"}
  )
  |> ForgeIssues.insert_numbered_identity(
    :pull_issue,
    repository,
    actor,
    :pull_request,
    %{title: "First pull", body: nil}
  )

assert {:ok, %{issue: issue, pull_issue: pull_issue}} = Fornacast.Repo.transaction(multi)
assert {issue.number, issue.kind} == {1, :issue}
assert {pull_issue.number, pull_issue.kind} == {2, :pull_request}
~~~

Add a forced failure after identity insertion and assert the sequence increment rolls back:

~~~elixir
failed =
  Ecto.Multi.new()
  |> ForgeIssues.insert_numbered_identity(
    :issue,
    repository,
    actor,
    :issue,
    %{title: "Rolled back"}
  )
  |> Ecto.Multi.run(:forced_failure, fn _repo, _changes -> {:error, :forced_failure} end)

assert {:error, :forced_failure, :forced_failure, _changes} =
         Fornacast.Repo.transaction(failed)

assert {:ok, %{issue: %{number: 1}}} =
         Ecto.Multi.new()
         |> ForgeIssues.insert_numbered_identity(
           :issue,
           repository,
           actor,
           :issue,
           %{title: "Committed"}
         )
         |> Fornacast.Repo.transaction()
~~~

- [ ] **Step 2: Run the allocator test and verify the missing modules**

Run:

~~~bash
mix test apps/forge_issues/test/number_allocator_test.exs --max-cases 1
~~~

Expected: compile failure because `ForgeIssues.insert_numbered_identity/6` and the schema modules do not exist.

- [ ] **Step 3: Implement the schema contracts**

Use string-backed `Ecto.Enum` fields and no cross-context associations. `ForgeIssues.Issue` has persisted fields matching the migration plus these virtual loaded values:

Define the sequence schema with the repository ID as its only primary key:

~~~elixir
defmodule ForgeIssues.NumberSequence do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "repository_number_sequences" do
    field(:repository_id, :integer, primary_key: true)
    field(:next_number, :integer, default: 1)
    timestamps(type: :utc_datetime)
  end

  def changeset(sequence, attrs) do
    sequence
    |> cast(attrs, [:repository_id])
    |> validate_required([:repository_id])
    |> unique_constraint(:repository_id)
  end
end
~~~

`Issue`, `Comment`, `Label`, `IssueLabel`, and `IssueAssignee` declare every migration column with plain `field/3` calls. They do not declare cross-context Ecto associations. `Comment` also has virtual `author` and `author_association` fields for the serializer.

~~~elixir
field(:labels, {:array, :map}, virtual: true, default: [])
field(:assignees, {:array, :map}, virtual: true, default: [])
field(:author, :map, virtual: true)
field(:author_association, :string, virtual: true, default: "NONE")
field(:comment_count, :integer, virtual: true, default: 0)
~~~

Define separate create and update changesets:

~~~elixir
def create_changeset(issue, attrs) do
  issue
  |> cast(attrs, [:title, :body, :state, :state_reason])
  |> validate_required([:repository_id, :number, :kind, :title, :state, :author_user_id])
  |> validate_inclusion(:kind, [:issue, :pull_request])
  |> validate_inclusion(:state, [:open, :closed])
  |> validate_inclusion(:state_reason, [:completed, :not_planned, :reopened])
  |> validate_length(:title, min: 1, max: 256)
  |> reject_null_bytes([:title, :body])
  |> normalize_closed_fields()
  |> unique_constraint([:repository_id, :number])
end

def update_changeset(issue, attrs) do
  issue
  |> cast(attrs, [:title, :body, :state, :state_reason])
  |> validate_required([:title, :state])
  |> validate_inclusion(:state, [:open, :closed])
  |> validate_inclusion(:state_reason, [:completed, :not_planned, :reopened])
  |> validate_length(:title, min: 1, max: 256)
  |> reject_null_bytes([:title, :body])
  |> normalize_closed_fields()
end
~~~

`normalize_closed_fields/1` sets `closed_at` to second-truncated UTC when transitioning to closed, clears it when reopening, permits `completed` or `not_planned` only for closed state, and permits `reopened` only for open state. Reject null bytes with a field error instead of letting PostgreSQL reject the SQL statement.

`Comment.changeset/2` requires a non-empty body and rejects null bytes. `Label.changeset/2` lowercases and trims `normalized_name`, requires a six-digit lowercase hexadecimal color, and enforces the repository/name uniqueness constraint. The two join schemas cast only their integer IDs and enforce their pair uniqueness constraints.

Return the foundation `%Fornacast.Page{entries: entries, total: total, page: page, per_page: per_page}` value from every issue and comment collection. Do not add a second page struct.

- [ ] **Step 4: Implement the transaction-owned allocator**

Implement `insert_numbered_identity/6` exactly as an `Ecto.Multi` builder:

~~~elixir
def insert_numbered_identity(multi, key, repository, actor, kind, attrs)
    when kind in [:issue, :pull_request] do
  sequence_key = {key, :sequence}
  number_key = {key, :number}

  multi
  |> Ecto.Multi.insert(
    sequence_key,
    NumberSequence.changeset(%NumberSequence{}, %{repository_id: repository.id}),
    on_conflict: :nothing,
    conflict_target: [:repository_id]
  )
  |> Ecto.Multi.run(number_key, fn repo, _changes ->
    query = from(sequence in NumberSequence, where: sequence.repository_id == ^repository.id)

    case repo.update_all(query, inc: [next_number: 1]) do
      {1, _rows} ->
        next_number = repo.one!(from(sequence in query, select: sequence.next_number))
        {:ok, next_number - 1}

      {0, _rows} ->
        {:error, {:unavailable, :database}}
    end
  end)
  |> Ecto.Multi.insert(key, fn changes ->
    %Issue{
      repository_id: repository.id,
      number: Map.fetch!(changes, number_key),
      kind: kind,
      author_user_id: actor.id
    }
    |> Issue.create_changeset(attrs)
  end)
end
~~~

The row update and subsequent read execute inside the caller's outer transaction. PostgreSQL row-update serialization and Turso's transactional write serialization guarantee that concurrent callers observe distinct values.

Implement `update_identity/5` as:

~~~elixir
def update_identity(multi, key, %Issue{} = issue, actor, attrs) do
  Ecto.Multi.update(multi, key, fn _changes ->
    issue
    |> authorize_identity_update(actor)
    |> case do
      :ok -> Issue.update_changeset(issue, attrs)
      {:error, reason} -> Ecto.Changeset.add_error(Issue.update_changeset(issue, %{}), :actor, Atom.to_string(reason))
    end
  end)
end
~~~

The outer `update/6` maps the private actor changeset error back to `{:error, :forbidden}`. Pull creation and merge use these builders without opening nested transactions.

- [ ] **Step 5: Prove concurrent issue and pull identities are unique**

Create eight tasks that wait for a `:go` message, then each transact one identity with alternating `:issue` and `:pull_request` kinds. For PostgreSQL, grant every task access before sending `:go`:

~~~elixir
if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
  Enum.each(tasks, fn task ->
    Ecto.Adapters.SQL.Sandbox.allow(Fornacast.Repo, self(), task.pid)
  end)
end

Enum.each(tasks, fn task -> send(task.pid, :go) end)

numbers =
  tasks
  |> Enum.map(&Task.await(&1, 15_000))
  |> Enum.map(fn {:ok, number} -> number end)
  |> Enum.sort()

assert numbers == Enum.to_list(1..8)
~~~

- [ ] **Step 6: Run allocator tests and commit**

Run:

~~~bash
mix test apps/forge_issues/test/number_allocator_test.exs --max-cases 1
~~~

Expected: sequential, rollback, mixed-kind, and concurrent-allocation tests pass.

Commit:

~~~bash
git add apps/forge_issues/lib/forge_issues.ex apps/forge_issues/lib/forge_issues/number_sequence.ex apps/forge_issues/lib/forge_issues/issue.ex apps/forge_issues/lib/forge_issues/comment.ex apps/forge_issues/lib/forge_issues/label.ex apps/forge_issues/lib/forge_issues/issue_label.ex apps/forge_issues/lib/forge_issues/issue_assignee.ex apps/forge_issues/test/number_allocator_test.exs
git commit -m "feat(issues): allocate shared repository numbers"
~~~

### Task 3: Provision default labels and normalize issue relationships

**Files:**

- Create: `apps/forge_issues/lib/forge_issues/default_labels.ex`
- Modify: `apps/forge_issues/lib/forge_issues.ex`
- Create: `apps/forge_issues/test/forge_issues_test.exs`

- [ ] **Step 1: Write failing default-label and relationship tests**

Cover all of these public behaviors:

- the first issue-domain read on an issue-enabled repository inserts exactly nine default labels;
- repeated and concurrent provisioning leaves exactly nine rows;
- a repository created before this migration receives the same defaults lazily;
- an issue-disabled repository is not provisioned;
- writers assign existing labels by a string or `%{"name" => name}` and the stored join set is replaced atomically;
- label matching trims and compares case-insensitively while the response preserves the stored display name;
- unknown labels return `{:validation, [%{resource: "Issue", field: "labels", code: :missing}]}` for writers;
- eligible active users with repository read access may be assigned;
- missing, disabled, organization, or repository-ineligible accounts return `{:validation, [%{resource: "Issue", field: "assignees", code: :invalid}]}` for writers;
- authors without repository write access may submit label and assignee fields, but those fields do not change stored relationships.

- [ ] **Step 2: Run the issue tests and verify labels are absent**

Run:

~~~bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
~~~

Expected: failures identify the missing default-label provisioning and relationship operations.

- [ ] **Step 3: Define the exact default set**

Create `ForgeIssues.DefaultLabels` with immutable rows:

~~~elixir
@labels [
  %{name: "bug", color: "d73a4a", description: "Something isn't working"},
  %{name: "documentation", color: "0075ca", description: "Improvements or additions to documentation"},
  %{name: "duplicate", color: "cfd3d7", description: "This issue or pull request already exists"},
  %{name: "enhancement", color: "a2eeef", description: "New feature or request"},
  %{name: "good first issue", color: "7057ff", description: "Good for newcomers"},
  %{name: "help wanted", color: "008672", description: "Extra attention is needed"},
  %{name: "invalid", color: "e4e669", description: "This doesn't seem right"},
  %{name: "question", color: "d876e3", description: "Further information is requested"},
  %{name: "wontfix", color: "ffffff", description: "This will not be worked on"}
]
~~~

`ensure/1` inserts all rows with second-truncated timestamps, `default: true`, normalized names, `on_conflict: :nothing`, and conflict target `[:repository_id, :normalized_name]`. It returns labels ordered by normalized name. Call it only after confirming `repository.has_issues`.

- [ ] **Step 4: Resolve labels and assignees through explicit queries**

Normalize mutation fields with these deterministic rules:

~~~elixir
defp requested_label_names(attrs) do
  attrs
  |> Map.fetch("labels")
  |> case do
    :error -> :unchanged
    {:ok, labels} when is_list(labels) ->
      {:replace,
       Enum.map(labels, fn
         name when is_binary(name) -> normalize_label_name(name)
         %{"name" => name} when is_binary(name) -> normalize_label_name(name)
       end)}
  end
end

defp requested_assignee_names(attrs) do
  cond do
    Map.has_key?(attrs, "assignees") -> {:replace, Map.fetch!(attrs, "assignees")}
    Map.get(attrs, "assignee") in [nil, ""] -> :unchanged
    true -> {:replace, [Map.fetch!(attrs, "assignee")]}
  end
end
~~~

Reject malformed array entries during API validation. In the domain, query `Label` by `repository_id` and normalized names. Resolve assignees with `ForgeAccounts.get_user_by_username/1`, require `kind: :user` and `state: :active`, then require `Fornacast.Access.authorize(user, :repository_read, repository) == :ok`.

Replace join rows inside the issue mutation's outer `Ecto.Multi`:

~~~elixir
multi
|> Ecto.Multi.delete_all(
  {key, :delete_labels},
  from(join in IssueLabel, where: join.issue_id == ^issue.id)
)
|> Ecto.Multi.insert_all(
  {key, :insert_labels},
  IssueLabel,
  Enum.map(label_ids, &%{issue_id: issue.id, label_id: &1, inserted_at: now, updated_at: now})
)
~~~

Use the same delete/insert shape for assignees. For a non-writer author, remove `labels`, `assignee`, and `assignees` from the relationship input before resolution, so unknown submitted names are ignored as required.

- [ ] **Step 5: Load relationship data without cross-context associations**

Load labels with an explicit `IssueLabel -> Label` join and assignees with an explicit `IssueAssignee` query followed by `ForgeAccounts.get_user/1`. Load the author through `ForgeAccounts.get_user/1` and compute `author_association` as `OWNER`, `MEMBER`, `COLLABORATOR`, or `NONE` from the repository access context. Put these values into the issue schema's virtual fields. Compute `comment_count` in one grouped query for list pages; do not execute one count query per issue.

- [ ] **Step 6: Run relationship tests and commit**

Run:

~~~bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
~~~

Expected: default provisioning, case normalization, writer validation, author-ignore behavior, and assignment eligibility tests pass.

Commit:

~~~bash
git add apps/forge_issues/lib/forge_issues/default_labels.ex apps/forge_issues/lib/forge_issues.ex apps/forge_issues/test/forge_issues_test.exs
git commit -m "feat(issues): manage labels and assignees"
~~~

### Task 4: Implement issue lifecycle, permissions, filters, and audit

**Files:**

- Modify: `apps/forge_issues/lib/forge_issues.ex`
- Modify: `apps/forge_issues/lib/forge_issues/issue.ex`
- Modify: `apps/forge_issues/test/forge_issues_test.exs`

- [ ] **Step 1: Write failing lifecycle and authorization tests**

Use the public slug-based context functions and cover:

- anonymous users read issues from a public repository and cannot read a private repository;
- authenticated repository readers create issues in public and private repositories;
- an issue author edits title/body, closes with `state_reason: :completed`, and reopens with `state_reason: :reopened`;
- an author cannot edit another user's issue;
- repository writers edit every issue and set `completed` or `not_planned` reasons;
- site administrators retain repository-write behavior;
- `has_issues: false` returns a successful list containing only pull-backed rows and returns `:issues_disabled` for ordinary create, get, and update operations;
- a pull-backed identity remains readable when `has_issues` is false;
- every successful mutation inserts one audit event with action, actor, repository ID, result, request ID, API version, and token ID;
- validation, authorization, and transaction failures insert no success audit event.

Use this request metadata fixture:

~~~elixir
%{
  request_id: "req-issue-1",
  api_version: "2022-11-28",
  ip_address: "192.0.2.10",
  user_agent: "Octokit/9.0",
  token_id: 41
}
~~~

- [ ] **Step 2: Write failing deterministic filter tests**

Create issue and pull-backed rows with distinct authors, states, labels, assignees, timestamps, and comment counts. Assert:

~~~elixir
assert {:ok, %Fornacast.Page{entries: entries, total: 2, page: 1, per_page: 30}} =
         ForgeIssues.list(actor, "acme", "demo", %{
           state: :all,
           labels: ["bug", "help wanted"],
           assignee: "*",
           creator: "alice",
           sort: :updated,
           direction: :desc,
           since: ~U[2026-07-01 00:00:00Z],
           page: 1,
           per_page: 30
         })

assert [%ForgeIssues.Issue{}, %ForgeIssues.Issue{}] = entries
~~~

Test the full supported filter values:

- `state` is `open` by default and accepts `open`, `closed`, or `all`;
- comma-separated labels use AND semantics and accept at most 100 normalized names;
- `assignee` accepts an exact username, `*` for any assignee, or `none`;
- `creator` accepts an exact username;
- `sort` accepts `created`, `updated`, or `comments`;
- `direction` accepts `asc` or `desc`;
- `since` is an inclusive UTC timestamp;
- `page` defaults to 1 and `per_page` defaults to 30 with a maximum of 100;
- every ordering adds issue ID as the stable final tiebreaker;
- ordinary issue lists include `kind: :pull_request` rows.

Invalid values return `{:validation, errors}` with `resource: "Issue"`, the query-field name, and `code: :invalid` or `:unprocessable`.

- [ ] **Step 3: Run the issue tests and verify lifecycle functions are missing**

Run:

~~~bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
~~~

Expected: failures identify missing `list/4`, `get/4`, `create/5`, and `update/6` behavior.

- [ ] **Step 4: Centralize repository and issue-state authorization**

Use the repository context as the only lookup boundary:

~~~elixir
defp fetch_repository(actor, owner_slug, repo_slug, permission) do
  ForgeRepos.fetch_authorized_repository(actor, owner_slug, repo_slug, permission)
end

defp require_issues_enabled(%ForgeRepos.Repository{has_issues: true}), do: :ok
defp require_issues_enabled(%ForgeRepos.Repository{}), do: {:error, :issues_disabled}

defp require_identity_enabled(%ForgeRepos.Repository{has_issues: true}, %Issue{}), do: :ok
defp require_identity_enabled(%ForgeRepos.Repository{}, %Issue{kind: :pull_request}), do: :ok
defp require_identity_enabled(%ForgeRepos.Repository{}, %Issue{kind: :issue}),
  do: {:error, :issues_disabled}

defp scope_enabled_issue_kinds(query, %ForgeRepos.Repository{has_issues: true}), do: query

defp scope_enabled_issue_kinds(query, %ForgeRepos.Repository{}) do
  where(query, [issue], issue.kind == :pull_request)
end
~~~

For every public function, call `fetch_repository/4` before querying `Issue`. Preserve `:forbidden` for visible repositories after the repository context has applied private-resource masking.

Classify mutation capability explicitly:

~~~elixir
defp mutation_capability(actor, repository, %Issue{author_user_id: actor_id}) do
  cond do
    Fornacast.Access.allowed?(actor, :repository_write, repository) -> {:ok, :writer}
    actor.id == actor_id and Fornacast.Access.allowed?(actor, :repository_read, repository) ->
      {:ok, :author}
    true ->
      {:error, :forbidden}
  end
end
~~~

An `:author` mutation keeps only title, body, and state. Closing supplies `state_reason: :completed` and reopening supplies `state_reason: :reopened`. A `:writer` mutation may also keep state reason, labels, assignee, and assignees.

- [ ] **Step 5: Implement create and update as one SQL transaction each**

Create first ensures default labels, then builds one outer multi:

~~~elixir
Ecto.Multi.new()
|> insert_numbered_identity(:issue, repository, actor, :issue, identity_attrs)
|> put_relationship_operations(:issue, repository, actor, relationship_attrs, :writer_or_author)
|> Fornacast.Audit.record_multi(
  :audit,
  actor,
  "issue.created",
  "repository",
  repository.id,
  %{"result" => "success"},
  request_metadata: request_meta
)
|> Fornacast.Repo.transaction()
~~~

`put_relationship_operations/6` reads the inserted issue from the caller-selected key. For an author-level create, it discards label and assignee fields. For a writer, it resolves and replaces them.

Update uses `update_identity/5` and relationship replacement in the same multi. Record `issue.updated` against target type `"issue"` and the persisted issue ID. Convert the multi result to `{:ok, load_issue(issue)}` or the stable domain error; do not return raw multi step names to the API.

- [ ] **Step 6: Implement list/get with composed Ecto queries**

Build one issue query scoped by repository ID. Apply each filter through a separate pure query function:

~~~elixir
query =
  Issue
  |> where([issue], issue.repository_id == ^repository.id)
  |> scope_enabled_issue_kinds(repository)
  |> filter_state(filters.state)
  |> filter_labels(repository.id, filters.labels)
  |> filter_assignee(filters.assignee)
  |> filter_creator(filters.creator)
  |> filter_since(filters.since)
  |> order_issues(filters.sort, filters.direction)

total = Repo.aggregate(query, :count, :id)

entries =
  query
  |> limit(^filters.per_page)
  |> offset(^((filters.page - 1) * filters.per_page))
  |> Repo.all()
  |> load_issue_metadata()

{:ok,
 %Fornacast.Page{
   entries: entries,
   total: total,
   page: filters.page,
   per_page: filters.per_page
 }}
~~~

Use explicit join/subquery filters. Label filtering groups by issue ID and requires `count(distinct label.normalized_name) == requested_label_count`. Comment sorting joins one grouped comment-count subquery and uses zero for issues with no comments. Resolve creator and exact assignee usernames through `ForgeAccounts` before building their ID filters.

`get/4` queries by both repository ID and issue number, applies `require_identity_enabled/2`, and loads labels, assignees, and comment count in bounded set queries.

- [ ] **Step 7: Run lifecycle tests and commit**

Run:

~~~bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
~~~

Expected: lifecycle, permission, `has_issues`, audit, pagination, sorting, and filtering tests pass.

Commit:

~~~bash
git add apps/forge_issues/lib/forge_issues.ex apps/forge_issues/lib/forge_issues/issue.ex apps/forge_issues/test/forge_issues_test.exs
git commit -m "feat(issues): add issue lifecycle"
~~~

### Task 5: Implement issue comment lifecycle and pull conversation semantics

**Files:**

- Modify: `apps/forge_issues/lib/forge_issues.ex`
- Modify: `apps/forge_issues/lib/forge_issues/comment.ex`
- Modify: `apps/forge_issues/test/forge_issues_test.exs`

- [ ] **Step 1: Write failing comment tests**

Cover:

- anonymous comment reads on public repositories;
- private reads require repository access;
- authenticated repository readers create comments;
- comment authors edit and delete their own comments;
- repository writers edit and delete every comment;
- unrelated readers cannot mutate another author's comment;
- comment IDs are resolved through repository ID and issue ID, preventing cross-repository ID access;
- list order is ascending `created_at, id` and `since` is inclusive;
- comment pages use `%Fornacast.Page{}` with stable pagination;
- comments on ordinary issues return `:issues_disabled` when `has_issues` is false;
- comments on `kind: :pull_request` identities continue to read and mutate while `has_issues` is false;
- create, update, and delete each emit exactly one successful audit row and no duplicate row on error.

- [ ] **Step 2: Run the comment tests and verify the functions are missing**

Run:

~~~bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
~~~

Expected: comment lifecycle cases fail because the public comment functions are incomplete.

- [ ] **Step 3: Scope every comment query to the authorized repository**

Resolve a comment with an explicit join:

~~~elixir
defp get_comment_for_repository(repository, comment_id) do
  from(comment in Comment,
    join: issue in Issue,
    on: issue.id == comment.issue_id,
    where: comment.id == ^comment_id and issue.repository_id == ^repository.id,
    select: {comment, issue}
  )
  |> Repo.one()
end
~~~

Do not call `Repo.get(Comment, id)` before repository authorization. For issue-number routes, load the issue with repository ID and number before querying comments.

- [ ] **Step 4: Implement author-or-writer comment permission**

Use:

~~~elixir
defp authorize_comment_mutation(actor, repository, %Comment{author_user_id: author_id}) do
  cond do
    Fornacast.Access.allowed?(actor, :repository_write, repository) -> :ok
    actor.id == author_id and Fornacast.Access.allowed?(actor, :repository_read, repository) ->
      :ok
    true ->
      {:error, :forbidden}
  end
end
~~~

Creation requires an active ordinary user and repository read permission. All comment reads call `fetch_authorized_repository(actor, owner, repo, :repository_read)`. Comment mutation functions fetch with read permission first, then apply author-or-writer permission so authors are not incorrectly forced to have repository write.

- [ ] **Step 5: Make comment mutations and audit atomic**

Create and update use `Ecto.Multi.insert/3` or `Ecto.Multi.update/3` followed by `Fornacast.Audit.record_multi/8`. Delete uses:

~~~elixir
Ecto.Multi.new()
|> Ecto.Multi.delete(:comment, comment)
|> Fornacast.Audit.record_multi(
  :audit,
  actor,
  "issue_comment.deleted",
  "issue_comment",
  comment.id,
  %{"result" => "success"},
  request_metadata: request_meta
)
|> Repo.transaction()
~~~

Return `:ok` only for `{:ok, _changes}`. Map changeset, authorization, and repository errors to the stable domain contract.

- [ ] **Step 6: Implement filtered comment pages**

Normalize `since` as a UTC `DateTime` and use:

~~~elixir
query =
  from(comment in Comment,
    where: comment.issue_id == ^issue.id,
    order_by: [asc: comment.inserted_at, asc: comment.id]
  )

query =
  case filters.since do
    nil -> query
    since -> where(query, [comment], comment.updated_at >= ^since)
  end
~~~

Count before limit/offset and return the shared `Fornacast.Page`. Reject invalid `since`, page, or per-page values with the foundation validation-error shape.

- [ ] **Step 7: Run comment tests and commit**

Run:

~~~bash
mix test apps/forge_issues/test/forge_issues_test.exs --max-cases 1
~~~

Expected: comment access, ID scoping, pull conversation, pagination, audit, and mutation tests pass.

Commit:

~~~bash
git add apps/forge_issues/lib/forge_issues.ex apps/forge_issues/lib/forge_issues/comment.ex apps/forge_issues/test/forge_issues_test.exs
git commit -m "feat(issues): add issue comments"
~~~

### Task 6: Extend the pinned contracts and versioned issue codecs

**Files:**

- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`
- Modify: `apps/fornacast_api/priv/openapi/fornacast-overlay.json`
- Modify: `apps/fornacast_api/lib/fornacast_api/request_validator.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/issue.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/issue.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializer.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/url.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/issue.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/issue_comment.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/issue.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/issue_comment.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/issue_contract.ex`
- Create: `apps/fornacast_api/test/issue_contract_test.exs`
- Modify: `apps/fornacast_api/test/openapi_contract_test.exs`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/issues/pull-issue.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-comment.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-list.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/issues/issue-comment-list.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/issues/pull-issue.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-comment.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-list.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/issues/issue-comment-list.json`

- [ ] **Step 1: Add failing operation and golden-response tests**

For each API version, assert the foundation's full first-release schema already contains exactly these issue operations under slice `3` ownership:

~~~text
GET  /repos/{owner}/{repo}/issues
POST /repos/{owner}/{repo}/issues
GET  /repos/{owner}/{repo}/issues/{issue_number}
PATCH /repos/{owner}/{repo}/issues/{issue_number}
GET  /repos/{owner}/{repo}/issues/{issue_number}/comments
POST /repos/{owner}/{repo}/issues/{issue_number}/comments
PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}
DELETE /repos/{owner}/{repo}/issues/comments/{comment_id}
~~~

Assert both documents and the overlay now require implemented-through marker `"3"`. Assert `FornacastAPI.RequestValidator.validate/3` supports operation atoms `:issue_create`, `:issue_update`, `:issue_comment_create`, and `:issue_comment_update` for both versions. Assert `FornacastAPI.Serializer.render/4` supports `:issue`, `:issue_comment`, and `:label`.

Use one fixed issue (`id: 3001`, number `7`, title `API issue`, body `Track compatibility`, state `open`, author ID `41`, no assignees or labels, zero comments, timestamps `2026-07-21T00:00:00Z`) and one fixed comment (`id: 3101`, body `First comment`, the same author and timestamps). Build literal expected maps from the complete field maps in Step 6, including the foundation's complete literal simple-user map; do not derive expected maps by invoking the serializer under test. `issue.json` is the issue map, `pull-issue.json` is the same canonical identity with `kind: :pull_request` and a pull link whose `merged_at` is null, `issue-comment.json` is the comment map, and the two list files are one-element arrays of their corresponding singular maps. Check in the exact `JSON.encode!/1` result at all ten paths above, compare decoded files to those literal maps, and validate every fixture against its selected response schema.

- [ ] **Step 2: Run the contract test and verify issue codecs are absent**

Run:

~~~bash
mix test apps/fornacast_api/test/issue_contract_test.exs --max-cases 1
~~~

Expected: failures report the still-`2` delivery marker plus missing validator operations, serializers, and golden fixtures. The pinned issue paths themselves are already present.

- [ ] **Step 3: Advance the generated delivery marker without changing the manifest**

Use the unchanged foundation pruner with implemented-through slice `3`. It retains the complete first-release manifest and the issue, issue-comment, label, simple-user, validation-error, and pagination response shapes from the pinned GHES 3.21 description at commit `03ca9c1cac754ec9b8369dc75de8a8c753c6e087`. Preserve the existing `2022-11-28` and `2026-03-10` version documents separately.

Assert the foundation-generated overlay's existing keys contain these exact entries:

~~~elixir
assert overlay["mutation_fields"]
       |> Map.take([
         "POST /repos/{owner}/{repo}/issues",
         "PATCH /repos/{owner}/{repo}/issues/{issue_number}",
         "POST /repos/{owner}/{repo}/issues/{issue_number}/comments",
         "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}"
       ]) == %{
         "POST /repos/{owner}/{repo}/issues" => ~w(title body assignee assignees labels),
         "PATCH /repos/{owner}/{repo}/issues/{issue_number}" => ~w(title body state state_reason assignee assignees labels),
         "POST /repos/{owner}/{repo}/issues/{issue_number}/comments" => ~w(body),
         "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}" => ~w(body)
       }

assert overlay["required_mutation_fields"]
       |> Map.take([
         "POST /repos/{owner}/{repo}/issues",
         "POST /repos/{owner}/{repo}/issues/{issue_number}/comments",
         "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}"
       ]) == %{
         "POST /repos/{owner}/{repo}/issues" => ~w(title),
         "POST /repos/{owner}/{repo}/issues/{issue_number}/comments" => ~w(body),
         "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}" => ~w(body)
       }

assert overlay["query_fields"]["issues"] ==
         ~w(page per_page state labels assignee creator sort direction since)
assert overlay["query_fields"]["issue_comments"] == ~w(page per_page since)
assert overlay["divergences"]["unsupported_issue_features"] ==
         ~w(milestone type locked active_lock_reason)
~~~

Keep the existing pin metadata and full operation set unchanged. Do not add label-definition, milestone, reaction, event, timeline, lock, transfer, sub-issue, or issue-type operations.

Regenerate both artifacts:

~~~bash
rm -rf /tmp/fornacast-openapi-source
git clone --filter=blob:none --no-checkout https://github.com/github/rest-api-description.git /tmp/fornacast-openapi-source
git -C /tmp/fornacast-openapi-source checkout 03ca9c1cac754ec9b8369dc75de8a8c753c6e087 -- descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json
mix run scripts/prune_github_openapi.exs -- /tmp/fornacast-openapi-source apps/fornacast_api/priv/openapi 3
~~~

Expected: both generated files retain the complete first-release manifest and advance only the implemented-through marker from `2` to `3`.

- [ ] **Step 4: Implement exact mutation validation**

Each versioned issue validator has explicit accepted-key sets:

~~~elixir
@create_fields ~w(title body assignee assignees labels)
@update_fields ~w(title body state state_reason assignee assignees labels)
@comment_fields ~w(body)

def validate(:issue_create, body), do: validate_issue_create(body)
def validate(:issue_update, body), do: validate_issue_update(body)
def validate(:issue_comment_create, body), do: validate_comment(body)
def validate(:issue_comment_update, body), do: validate_comment(body)
~~~

Validation rules are:

- create requires a non-empty string `title`;
- `body` is null or a string;
- `state` is `open` or `closed`;
- `state_reason` is `completed`, `not_planned`, or `reopened`;
- `assignee` is null or a username string;
- `assignees` is an array of username strings;
- `labels` is an array whose entries are strings or objects containing only a string `name`;
- comment create/update requires a non-empty string `body`;
- every unrecognized body field produces `code: :unprocessable`;
- missing title/body produces `code: :missing_field`;
- wrong types and invalid enum values produce `code: :invalid`.

Return:

~~~elixir
{:error,
 {:validation,
  [
    %{
      resource: "Issue",
      field: "title",
      code: :missing_field
    }
  ]}}
~~~

Do not pass unknown fields to Ecto. Extend both version dispatcher modules with explicit function clauses and extend `FornacastAPI.RequestValidator.validate/3` without changing foundation operations.

- [ ] **Step 5: Parse filters independently from mutation bodies**

Implement `FornacastAPI.IssueContract.list_filters/1` and `comment_filters/1`. Start with `FornacastAPI.Pagination.parse/1`, then parse the exact filter enums and ISO-8601 UTC timestamps. Split labels on commas, trim non-empty values, and reject more than 100 labels:

~~~elixir
defp parse_labels(nil), do: {:ok, []}

defp parse_labels(value) when is_binary(value) do
  labels =
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if length(labels) <= 100 do
    {:ok, labels}
  else
    {:error,
     {:validation,
      [%{resource: "Issue", field: "labels", code: :unprocessable}]}}
  end
end
~~~

Unknown query fields are ignored. Defaults are `state: :open`, `sort: :created`, `direction: :desc`, `page: 1`, and `per_page: 30`.

- [ ] **Step 6: Implement explicit versioned response maps**

Both issue serializers emit the pinned fields explicitly. The common first-release values are:

~~~elixir
%{
  "url" => issue_api_url,
  "repository_url" => repository_api_url,
  "labels_url" => issue_api_url <> "/labels{/name}",
  "comments_url" => issue_api_url <> "/comments",
  "events_url" => issue_api_url <> "/events",
  "html_url" => issue_api_url,
  "id" => issue.id,
  "node_id" => Base.url_encode64("Issue:#{issue.id}", padding: false),
  "number" => issue.number,
  "title" => issue.title,
  "user" => rendered_author,
  "labels" => rendered_labels,
  "state" => Atom.to_string(issue.state),
  "locked" => false,
  "assignee" => List.first(rendered_assignees),
  "assignees" => rendered_assignees,
  "milestone" => nil,
  "comments" => issue.comment_count,
  "created_at" => DateTime.to_iso8601(issue.inserted_at),
  "updated_at" => DateTime.to_iso8601(issue.updated_at),
  "closed_at" => iso8601_or_nil(issue.closed_at),
  "author_association" => issue.author_association,
  "active_lock_reason" => nil,
  "draft" => false,
  "pull_request" => pull_request_link_or_nil,
  "body" => issue.body,
  "closed_by" => nil,
  "reactions" => empty_reactions,
  "timeline_url" => issue_api_url <> "/timeline",
  "performed_via_github_app" => nil,
  "state_reason" => enum_or_nil(issue.state_reason)
}
~~~

The serializer accepts `pull_links_by_issue_id` in its options, defaulting to an empty map. The pull link is `nil` for `kind: :issue`. For `kind: :pull_request`, read `Map.get(pull_links_by_issue_id, issue.id, %{merged_at: nil})`; the pull-request slice makes the API boundary supply `%{issue.id => %{merged_at: DateTime.t() | nil}}` for real pull rows. The serializer combines that value with this exact URL map:

~~~elixir
%{
  "url" => repository_api_url <> "/pulls/#{issue.number}",
  "html_url" => repository_api_url <> "/pulls/#{issue.number}",
  "diff_url" => repository_api_url <> "/pulls/#{issue.number}",
  "patch_url" => repository_api_url <> "/pulls/#{issue.number}",
  "merged_at" => iso8601_or_nil(pull_link.merged_at)
}
~~~

The issue slice's pull fixture passes `%{3001 => %{merged_at: nil}}`. Do not query pull tables from a serializer and do not add a `forge_issues -> forge_pulls` dependency. The pull-request plan later teaches the API boundary, which may depend on both domains, to batch-hydrate this map for real pull-backed issue responses.

Issue-comment serializers emit `url`, `html_url`, `issue_url`, `id`, local opaque `node_id`, rendered `user`, `created_at`, `updated_at`, `author_association`, `body`, empty `reactions`, and null `performed_via_github_app`. Label serializers emit `id`, local opaque `node_id`, `url`, `name`, `color`, `default`, and `description`.

Use the foundation user serializer through `FornacastAPI.Serializer.render(version, :simple_user, user, opts)`. Extend `FornacastAPI.URL` with issue, comment, label, and pull-link helpers and use that facade for every field; serializers never call the configuration module or read the request Host header. Per the approved deliberate divergence, issue and pull `html_url` fields use their corresponding public API URL until repository-scoped browser pages exist; API and existing repository-web URLs remain distinct helpers. Keep separate source modules for the two API versions and extend both version dispatchers explicitly.

- [ ] **Step 7: Pass contract tests and commit**

Run:

~~~bash
mix test apps/fornacast_api/test/issue_contract_test.exs --max-cases 1
~~~

Expected: both version artifacts contain the exact route subset, validator tests pass, and all issue/comment golden responses validate.

Commit:

~~~bash
git add apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json apps/fornacast_api/priv/openapi/fornacast-overlay.json apps/fornacast_api/lib/fornacast_api/request_validator.ex apps/fornacast_api/lib/fornacast_api/url.ex apps/fornacast_api/lib/fornacast_api/validators apps/fornacast_api/lib/fornacast_api/serializer.ex apps/fornacast_api/lib/fornacast_api/serializers apps/fornacast_api/lib/fornacast_api/issue_contract.ex apps/fornacast_api/test/openapi_contract_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/fixtures/2022-11-28/issues apps/fornacast_api/test/fixtures/2026-03-10/issues
git commit -m "feat(api): define issue contracts"
~~~

### Task 7: Route issue and comment requests through thin API controllers

**Files:**

- Modify: `apps/fornacast_api/mix.exs`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/error.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/issue_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/issue_comment_controller.ex`
- Create: `apps/fornacast_api/test/issue_controller_test.exs`

- [ ] **Step 1: Write failing route, scope, status, and privacy tests**

Test both API versions and assert:

- public issue and comment reads work anonymously;
- a supplied invalid token returns `401` instead of anonymous fallback;
- private reads require `repo` or legacy `repo:read`/`repo:write`;
- public creates and mutations require `public_repo` or `repo`;
- private creates and mutations require `repo`;
- legacy scopes never permit a REST mutation;
- missing mutation credentials return `401`;
- an insufficient PAT scope returns `403` with `Resource not accessible by personal access token`;
- a visible repository with insufficient user role returns `403` with `Forbidden`;
- inaccessible private repositories use the same `404` body as missing repositories;
- ordinary disabled-issue create/detail/update/comment operations return `410` with `Issues are disabled for this repository`, while the list returns `200` with pull-backed rows only;
- creates return `201`, reads and patches return `200`, and comment delete returns `204`;
- every response reports `X-OAuth-Scopes` and `X-Accepted-OAuth-Scopes` from the foundation scope contract.

- [ ] **Step 2: Run the controller test and verify routes are missing**

Run:

~~~bash
mix test apps/fornacast_api/test/issue_controller_test.exs --max-cases 1
~~~

Expected: requests return `404` because issue routes and controllers do not exist.

- [ ] **Step 3: Add the one-way API dependency and ordered routes**

Add `{:forge_issues, in_umbrella: true}` to `apps/fornacast_api/mix.exs`. Do not add `fornacast_api` to `forge_issues`.

Inside the existing `:api_context` scope, place global comment-ID routes before the `:issue_number` routes so `comments` cannot be captured as an issue number:

~~~elixir
scope "/api/v3", FornacastAPI do
  pipe_through(:api_context)

  patch(
    "/repos/:owner/:repo/issues/comments/:comment_id",
    IssueCommentController,
    :update
  )

  delete(
    "/repos/:owner/:repo/issues/comments/:comment_id",
    IssueCommentController,
    :delete
  )

  get("/repos/:owner/:repo/issues", IssueController, :index)
  post("/repos/:owner/:repo/issues", IssueController, :create)
  get("/repos/:owner/:repo/issues/:issue_number", IssueController, :show)
  patch("/repos/:owner/:repo/issues/:issue_number", IssueController, :update)

  get(
    "/repos/:owner/:repo/issues/:issue_number/comments",
    IssueCommentController,
    :index
  )

  post(
    "/repos/:owner/:repo/issues/:issue_number/comments",
    IssueCommentController,
    :create
  )
end
~~~

Use only the foundation `:api_context` pipeline. Mutation controllers resolve and authorize the repository first, then call `FornacastAPI.RequestBody.read_json(conn, :ordinary, [])`. This ordering masks private targets and rejects insufficient scopes before reading or parsing a body.

- [ ] **Step 4: Enforce PAT scopes before calling a mutation**

Read `conn.assigns.api_auth` as nil or `%FornacastAPI.Authentication{actor: actor, api_key: api_key}`. Resolve the repository through `ForgeRepos.fetch_authorized_repository/4` to obtain its visibility for scope evaluation, then use these exact clauses:

~~~elixir
defp authorize_scope(nil, :repository_read, :public), do: {:ok, []}

defp authorize_scope(%FornacastAPI.Authentication{api_key: api_key}, action, visibility) do
  accepted = ForgeAccounts.APIScope.accepted_scopes(action, visibility)

  case ForgeAccounts.APIScope.authorize(api_key, action, visibility) do
    :ok -> {:ok, accepted}
    {:error, :insufficient_scope} -> {:error, {:insufficient_scope, accepted}}
  end
end

defp authorize_scope(nil, _action, _visibility), do: {:error, :requires_authentication}

defp require_auth(%Plug.Conn{
       assigns: %{api_auth: %FornacastAPI.Authentication{} = authentication}
     }),
     do: {:ok, authentication}

defp require_auth(_conn), do: {:error, :requires_authentication}
~~~

The authentication plug has already rejected an invalid supplied token. For an anonymous public read, skip PAT authorization and use an empty accepted-scope list. For every mutation, reject a nil actor before body validation or the domain call. The Git-data slice's exact `Error.from_domain({:insufficient_scope, accepted}, url)` clause preserves `X-Accepted-OAuth-Scopes` on the `403` path.

Repository resolution here chooses the compatible PAT scope and response headers. `ForgeIssues` repeats the authoritative repository lookup internally before any issue query or write, preserving domain authorization when called outside HTTP.

- [ ] **Step 5: Validate, call one issue operation, and serialize**

Implement create in this shape:

~~~elixir
def create(conn, %{"owner" => owner, "repo" => repo}) do
  version = conn.assigns.api_version

  with {:ok, %{actor: actor} = authentication} <- require_auth(conn),
       {:ok, repository} <-
         ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
       {:ok, accepted_scopes} <-
         authorize_scope(
           authentication,
           :repository_mutation,
           repository.visibility
         ),
       {:ok, body, conn} <-
         FornacastAPI.RequestBody.read_json(conn, :ordinary, []),
       {:ok, attrs} <-
         FornacastAPI.RequestValidator.validate(version, :issue_create, body),
       {:ok, issue} <-
         ForgeIssues.create(
           actor,
           owner,
           repo,
           attrs,
           FornacastAPI.Plugs.RequestContext.metadata(conn)
         ) do
    body =
      FornacastAPI.Serializer.render(version, :issue, issue,
        owner: owner,
        repo: repo
      )

    FornacastAPI.Response.json(conn, 201, body, accepted_scopes: accepted_scopes)
  else
    {:error, %FornacastAPI.Error{} = error, _reason, conn} ->
      FornacastAPI.Response.error(conn, error)

    {:error, reason} ->
      reason
      |> FornacastAPI.Error.from_domain(
        "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#create-an-issue"
      )
      |> then(&FornacastAPI.Response.error(conn, &1))
  end
end
~~~

Add the issue-disabled error clause:

~~~elixir
def from_domain(:requires_authentication, url) do
  new(401, "Requires authentication", url)
end

def from_domain(:issues_disabled, url) do
  new(410, "Issues are disabled for this repository", url)
end
~~~

Index parses `IssueContract.list_filters/1` and responds with `Response.paginated/5`. Show parses a positive issue number. Update validates `:issue_update`. Comment create/update validate their matching operation; comment index parses `comment_filters/1`; delete returns `Response.no_content(conn)`. Each action passes the full operation-specific GHES 3.21 documentation URL to the shared error mapper.

Controllers contain no Ecto query, label/assignee resolution, author rule, transaction, or audit insertion.

- [ ] **Step 6: Pass scoped controller tests and commit**

Run:

~~~bash
mix test apps/fornacast_api/test/issue_controller_test.exs --max-cases 1
~~~

Expected: route, authentication, scope, privacy masking, status, error-shape, and OAuth-scope header tests pass for both API versions.

Commit:

~~~bash
git add apps/fornacast_api/mix.exs apps/fornacast_api/lib/fornacast_api/router.ex apps/fornacast_api/lib/fornacast_api/error.ex apps/fornacast_api/lib/fornacast_api/controllers/issue_controller.ex apps/fornacast_api/lib/fornacast_api/controllers/issue_comment_controller.ex apps/fornacast_api/test/issue_controller_test.exs
git commit -m "feat(api): serve issues and comments"
~~~

### Task 8: Prove the complete issue workflow and adapter contract

**Files:**

- Create: `apps/fornacast_api/test/issue_workflow_test.exs`
- Modify: `apps/forge_issues/test/number_allocator_test.exs`
- Modify: `apps/forge_issues/test/forge_issues_test.exs`
- Modify: `apps/fornacast_api/test/issue_contract_test.exs`
- Modify: `apps/fornacast_api/test/issue_controller_test.exs`

- [ ] **Step 1: Write the end-to-end first-release issue workflow**

Provision an ordinary user, a writer, a public repository, a private repository, and classic PATs through domain fixtures. Against `/api/v3`:

1. create an issue as a repository reader;
2. verify the number is 1 and reader-submitted labels/assignees were ignored;
3. edit title/body as the author;
4. create and edit a comment as the comment author;
5. assign `bug` and an eligible assignee as a writer;
6. filter the list by state, label, assignee, creator, and since;
7. close with `state_reason: completed`;
8. reopen with `state_reason: reopened`;
9. delete the comment as its author;
10. assert every JSON response validates against the selected pinned schema;
11. assert audit rows contain safe request metadata and never contain the PAT or request body.

Repeat the workflow's create, read, comment, close, and reopen operations with both supported `X-GitHub-Api-Version` values.

- [ ] **Step 2: Add disabled-issue and pull-identity acceptance cases**

Insert one ordinary identity and one pull-backed identity, then set `has_issues` false. Assert issue list returns `200` with only the pull-backed row; ordinary create/get/update/comment operations return `410`; and the pull-backed identity and its comments remain available through the compatible issue-number and comment routes.

- [ ] **Step 3: Add final concurrency and pagination checks**

Run 20 concurrent transactions alternating ordinary and pull-backed identities. Assert exactly the integers 1 through 20 are allocated once. Create 105 issues, request `per_page=100`, and assert:

~~~elixir
assert [first_link, next_link, last_link] =
         response
         |> Plug.Conn.get_resp_header("link")
         |> List.first()
         |> String.split(", ")
         |> Enum.map(&String.trim/1)

assert first_link =~ ~s(rel="first")
assert next_link =~ ~s(rel="next")
assert last_link =~ ~s(rel="last")
~~~

Request page 2 and assert five distinct issue IDs in deterministic order with no overlap from page 1.

- [ ] **Step 4: Run every in-scope Turso test**

Run:

~~~bash
MIX_ENV=test mix ecto.migrate
mix test apps/forge_issues/test apps/fornacast_api/test/issue_controller_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/issue_workflow_test.exs apps/fornacast_web/test/fornacast_run_task_test.exs --max-cases 1
~~~

Expected: all issue-domain, issue-API, contract, workflow, allocator, and service-list tests pass.

- [ ] **Step 5: Run the same scoped contract with PostgreSQL**

With the test PostgreSQL service configured, run in a clean compile:

~~~bash
FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test mix clean
FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test mix ecto.create --quiet
FORNACAST_DATABASE_ADAPTER=postgres MIX_ENV=test mix ecto.migrate
FORNACAST_DATABASE_ADAPTER=postgres mix test apps/forge_issues/test apps/fornacast_api/test/issue_controller_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/issue_workflow_test.exs --max-cases 1
~~~

Expected: the same scoped suites pass, including concurrent shared-number allocation and all migration constraints.

- [ ] **Step 6: Format, verify the diff, and commit the acceptance suite**

Run:

~~~bash
mix format --check-formatted apps/forge_issues apps/fornacast_api apps/fornacast/priv/repo/migrations/20260721000300_create_issue_domain.exs apps/fornacast_web/lib/mix/tasks/fornacast.run.ex apps/fornacast_web/test/fornacast_run_task_test.exs mix.exs
git diff --check
~~~

Expected: formatting and whitespace checks pass.

Commit:

~~~bash
git add apps/fornacast_api/test/issue_workflow_test.exs apps/forge_issues/test/number_allocator_test.exs apps/forge_issues/test/forge_issues_test.exs apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/issue_controller_test.exs
git commit -m "test(api): verify issue workflow"
~~~
