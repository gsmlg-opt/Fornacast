defmodule ForgeImports.RunViewConsistencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi

  alias ForgeImports.{
    DiscoveryWorker,
    ImportAttempt,
    ImportRun,
    PageCheckpoint,
    Persistence,
    RepositoryItem,
    RunView
  }

  alias ForgeImports.GitHub.Repository
  alias ForgeRepos.Repository, as: LocalRepository
  alias Fornacast.Repo

  @telemetry_event [:fornacast, :repo, :query]

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    account = saved_account_fixture(actor)
    {:ok, reference} = ForgeAccounts.github_account_reference(actor, account.identity_id)

    {:ok, run} =
      ForgeImports.create_run(actor, %{
        source_kind: :repository,
        github_identity_id: account.identity_id,
        credential_source: :saved,
        github_credential_id: reference.credential.credential_id,
        source_owner_login: "octocat",
        source_repository_full_name: "octocat/coherent-view",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        request_metadata: request_metadata()
      })

    %{actor: actor, run: run}
  end

  test "run view retries when discovery commits between the run and child queries", %{
    actor: actor,
    run: run
  } do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        &__MODULE__.pause_after_run_read/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    reader =
      Task.async(fn ->
        Process.put({__MODULE__, :coherent_reader}, true)
        ForgeImports.get_run(actor, run.id)
      end)

    assert_receive {:run_view_paused, reader_pid}, 2_000

    assert {:ok, :awaiting_resolution} =
             DiscoveryWorker.perform(run.id,
               owner: "coherent-view-worker",
               lease_seconds: 60,
               client: __MODULE__.RepositoryClient,
               client_options: []
             )

    send(reader_pid, :continue_run_view)

    assert {:ok,
            %RunView{
              state: :awaiting_resolution,
              counts: %{selected: 1},
              repositories: [%{source_full_name: "octocat/coherent-view"}]
            }} = Task.await(reader, 5_000)
  end

  test "run view retries when a conflict plan commits between the run and item queries", %{
    actor: actor,
    run: run
  } do
    collision_repository_fixture(actor, "coherent-view")

    assert {:ok, :awaiting_resolution} =
             DiscoveryWorker.perform(run.id,
               owner: "coherent-conflict-worker",
               lease_seconds: 60,
               client: __MODULE__.RepositoryClient,
               client_options: []
             )

    old_updated_at = ~U[2026-08-26 09:00:00Z]

    ImportRun
    |> where([candidate], candidate.id == ^run.id)
    |> Repo.update_all(set: [updated_at: old_updated_at])

    {:ok, before_view} = ForgeImports.get_run(actor, run.id)
    assert [%{id: item_id, state: :awaiting_resolution}] = before_view.repositories

    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        &__MODULE__.pause_after_run_read/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    reader =
      Task.async(fn ->
        Process.put({__MODULE__, :coherent_reader}, true)
        ForgeImports.get_run(actor, run.id)
      end)

    assert_receive {:run_view_paused, reader_pid}, 2_000

    assert {:ok, %RunView{repositories: [%{destination_slug: "resolved-view"}]}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{item_id => %{action: :rename, slug: "resolved-view"}},
               request_metadata()
             )

    committed_updated_at = Repo.get!(ImportRun, run.id).updated_at
    refute committed_updated_at == old_updated_at
    send(reader_pid, :continue_run_view)

    assert {:ok,
            %RunView{
              updated_at: ^committed_updated_at,
              repositories: [
                %{
                  id: ^item_id,
                  destination_slug: "resolved-view",
                  conflict_action: :rename,
                  state: :queued
                }
              ]
            }} = Task.await(reader, 5_000)
  end

  test "run view retries when publication commits after the parent read", %{
    actor: actor,
    run: run
  } do
    fixture = ready_publication_fixture(actor, run, :create)
    {reader, reader_pid} = paused_run_reader(actor, run.id)

    assert {:ok, %{repository: repository}} =
             ForgeImports.publish_repository(actor, fixture.item.id, request_metadata())

    send(reader_pid, :continue_run_view)

    assert {:ok,
            %RunView{
              counts: %{published: 1},
              repositories: [%{id: item_id, state: :published}]
            }} = Task.await(reader, 5_000)

    assert item_id == fixture.item.id
    assert repository.id == fixture.shadow.id
  end

  test "run view retries when capability-owned publication drift commits after the parent read",
       %{
         actor: actor,
         run: run
       } do
    target = collision_repository_fixture(actor, "view-drift-target")
    fixture = ready_publication_fixture(actor, run, {:replace, target})
    {reader, reader_pid} = paused_run_reader(actor, run.id)

    assert {1, _rows} =
             Repo.update_all(
               from(repository in LocalRepository, where: repository.id == ^target.id),
               inc: [write_version: 1]
             )

    assert {:error, :destination_changed} =
             ForgeImports.publish_repository(actor, fixture.item.id, request_metadata())

    send(reader_pid, :continue_run_view)

    assert {:ok,
            %RunView{
              counts: %{published: 0},
              repositories: [
                %{id: item_id, state: :awaiting_resolution, wait_reason: "destination_changed"}
              ]
            }} = Task.await(reader, 5_000)

    assert item_id == fixture.item.id
  end

  @doc false
  def pause_after_run_read(_event, _measurements, metadata, parent) do
    if Process.get({__MODULE__, :coherent_reader}) == true and
         Process.get({__MODULE__, :run_view_paused}) != true and
         is_binary(metadata[:query]) and
         String.contains?(metadata.query, "github_import_runs") do
      Process.put({__MODULE__, :run_view_paused}, true)
      send(parent, {:run_view_paused, self()})

      receive do
        :continue_run_view -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defmodule RepositoryClient do
    def repository(_pat, "octocat", "coherent-view", _opts) do
      {:ok,
       %Repository{
         id: 94_001,
         owner_id: 84_001,
         name: "coherent-view",
         full_name: "octocat/coherent-view",
         owner_login: "octocat",
         description: nil,
         visibility: :private,
         default_branch: "main",
         has_issues: true,
         allow_merge_commit: true,
         fork: false,
         archived: false,
         html_url: "https://github.com/octocat/coherent-view",
         updated_at: ~U[2026-08-26 10:00:00Z],
         pushed_at: ~U[2026-08-26 10:00:00Z]
       }}
    end
  end

  defp paused_run_reader(actor, run_id) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        &__MODULE__.pause_after_run_read/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    reader =
      Task.async(fn ->
        Process.put({__MODULE__, :coherent_reader}, true)
        ForgeImports.get_run(actor, run_id)
      end)

    assert_receive {:run_view_paused, reader_pid}, 2_000
    {reader, reader_pid}
  end

  defp ready_publication_fixture(actor, run, action) do
    target =
      case action do
        {:replace, target} -> target
        :create -> nil
      end

    slug = if target, do: target.slug, else: "view-publication"

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in ImportRun, where: candidate.id == ^run.id),
               set: [
                 state: :running,
                 selected_count: 1,
                 source_owner_github_id: 84_001,
                 source_repository_github_id: 94_001,
                 source_repository_full_name: "octocat/coherent-view",
                 source_metadata: %{}
               ]
             )

    item =
      %{
        import_run_id: run.id,
        github_repository_id: 95_000 + System.unique_integer([:positive]),
        source_full_name: "octocat/#{slug}",
        source_name: "Coherent publication",
        source_metadata: %{
          "default_branch" => "main",
          "visibility" => "private",
          "description" => nil,
          "has_issues" => true,
          "allow_merge_commit" => true,
          "fork" => false,
          "archived" => false
        },
        source_observed_at: ~U[2026-08-28 02:00:00Z],
        selected: true,
        destination_owner_id: actor.id,
        destination_slug: slug,
        destination_visibility: :private,
        conflict_action: if(target, do: :replace),
        replacement_repository_id: target && target.id,
        replacement_owner_id: target && target.owner_user_id,
        replacement_storage_path: target && target.storage_path,
        replacement_generation: target && target.generation,
        replacement_write_version: target && target.write_version,
        replacement_updated_at: target && target.updated_at,
        replacement_last_pushed_at: target && target.last_pushed_at,
        state: :queued,
        attempt_count: 1
      }
      |> Persistence.insert_repository_item()
      |> unwrap!()

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, actor.id, %{
        item_id: item.id,
        generation: if(target, do: target.generation + 1, else: 1)
      })
      |> Repo.transaction()

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :ready_to_publish,
                 hidden_repository_id: shadow.id,
                 staged_storage_path: ForgeRepos.absolute_storage_path(shadow),
                 checkpoint: %{"git_staged" => true, "unsupported_scan" => "complete"},
                 source_git: %{
                   "empty" => false,
                   "default_branch" => "main",
                   "refs" => 1,
                   "bytes" => 1,
                   "lfs_detected" => false,
                   "submodules_detected" => false,
                   "scan_truncated" => false
                 }
               ]
             )

    item = Repo.get!(RepositoryItem, item.id)

    decision =
      if target do
        %{
          "action" => "replace",
          "slug" => target.slug,
          "replacement_repository_id" => target.id,
          "replacement_owner_id" => target.owner_user_id,
          "replacement_storage_path" => target.storage_path,
          "replacement_generation" => target.generation,
          "replacement_write_version" => target.write_version,
          "replacement_updated_at" => target.updated_at,
          "replacement_last_pushed_at" => target.last_pushed_at
        }
      else
        %{"action" => "create", "slug" => slug}
      end

    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: decision,
      started_at: ~U[2026-08-28 02:00:00Z]
    })
    |> Repo.insert!()

    for resource <- ~w(labels issues comments pull_requests number_sequence) do
      %PageCheckpoint{}
      |> PageCheckpoint.create_changeset(%{
        repository_item_id: item.id,
        resource_kind: resource,
        page_key: "__terminal_v1__",
        item_count: 0,
        cursor_metadata: %{},
        committed_at: ~U[2026-08-28 02:00:00Z]
      })
      |> Repo.insert!()
    end

    %{item: item, shadow: shadow, target: target}
  end

  defp saved_account_fixture(actor) do
    assert {:ok, account} =
             ForgeAccounts.save_github_account(
               actor,
               %{
                 github_user_id: 74_001,
                 login: "view-account",
                 avatar_url: nil,
                 profile_url: "https://github.com/view-account"
               },
               "unrelated-view-token",
               request_metadata()
             )

    account
  end

  defp collision_repository_fixture(actor, slug) do
    %LocalRepository{owner_user_id: actor.id, storage_path: "@test/#{slug}.git"}
    |> LocalRepository.create_changeset(%{
      slug: slug,
      name: slug,
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true
    })
    |> Repo.insert!()
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "run-view-#{suffix}",
        email: "run-view-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp request_metadata do
    suffix = System.unique_integer([:positive])

    %{
      "request_id" => "run-view-request-#{suffix}",
      "operation_id" => "run-view-operation-#{suffix}",
      "ip_address" => "203.0.113.21",
      "user_agent" => "run-view-consistency-test"
    }
  end

  defp unwrap!({:ok, value}), do: value

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "api_keys",
          "ssh_keys",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
