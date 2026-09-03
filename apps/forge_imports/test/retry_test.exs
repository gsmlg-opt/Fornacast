defmodule ForgeImports.RetryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi

  alias ForgeAccounts.{GitHubCredential, User}

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    ObjectMapping,
    PageCheckpoint,
    Persistence,
    RepositoryItem
  }

  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, Repo}

  @now ~U[2026-08-25 12:00:00Z]
  @pat "github_pat_retry_test_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<11>>, 32)}}
  @terminal_resources ~w(labels issues comments pull_requests number_sequence)

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor)
    credential = saved_credential_fixture!(actor, identity)

    %{
      actor: actor,
      identity: identity,
      credential: credential,
      view: %{identity_id: identity.id}
    }
  end

  test "retry_import creates a successor with predecessor links for partial organization success",
       %{
         actor: actor,
         identity: identity,
         credential: credential
       } do
    predecessor = terminal_org_run!(actor, identity, :completed_with_warnings)

    published = org_item!(predecessor, actor, 9_100_000_001, "alpha", state: :failed)

    {1, _} =
      Repo.update_all(
        from(item in RepositoryItem, where: item.id == ^published.id),
        set: [state: :published, publication_evidence: %{"published_repository_id" => 1}]
      )

    failed = org_item!(predecessor, actor, 9_100_000_002, "beta", state: :failed)

    skipped =
      org_item!(predecessor, actor, 9_100_000_003, "gamma", state: :skipped, selected: false)

    metadata = request_metadata("partial-org-retry")

    assert {:ok, successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               metadata
             )

    assert successor.predecessor_run_id == predecessor.id
    assert successor.state == :ready
    assert length(successor.repositories) == 1

    assert [%{predecessor_item_id: predecessor_item_id, state: :queued}] =
             successor.repositories

    assert predecessor_item_id == failed.id
    refute predecessor_item_id in [published.id, skipped.id]
    assert Repo.get!(ImportRun, predecessor.id).state == :completed_with_warnings
    assert Repo.get!(RepositoryItem, published.id).state == :published
  end

  test "failed and canceled predecessors are retryable", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    for terminal_state <- [:failed, :canceled] do
      predecessor = terminal_org_run!(actor, identity, terminal_state)

      _item =
        org_item!(
          predecessor,
          actor,
          System.unique_integer([:positive]),
          "retry-#{terminal_state}"
        )

      assert {:ok, successor} =
               ForgeImports.retry_import(
                 actor,
                 predecessor.id,
                 saved_source(credential, identity),
                 request_metadata("retry-#{terminal_state}")
               )

      assert successor.predecessor_run_id == predecessor.id
      assert Enum.all?(successor.repositories, &(&1.predecessor_item_id != nil))
    end
  end

  test "retry excludes intentional skips and published repositories", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)

    _skipped =
      org_item!(predecessor, actor, 9_100_000_010, "skipped-repo",
        state: :skipped,
        selected: false
      )

    _published =
      org_item!(predecessor, actor, 9_100_000_011, "published-repo", state: :failed)

    {1, _} =
      Repo.update_all(
        from(item in RepositoryItem, where: item.source_name == "published-repo"),
        set: [state: :published, publication_evidence: %{"published_repository_id" => 42}]
      )

    retryable =
      org_item!(predecessor, actor, 9_100_000_012, "failed-repo", state: :failed)

    assert {:ok, successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("exclude-published")
             )

    assert [only] = successor.repositories
    assert only.predecessor_item_id == retryable.id
  end

  test "retry adopts validated staging, checkpoints, and mappings", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    item = staged_item!(predecessor, actor, slug: "staged-retry")

    assert {:ok, successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("adopt-staging")
             )

    assert [summary] = successor.repositories
    reloaded = Repo.get!(RepositoryItem, summary.id)
    assert reloaded.predecessor_item_id == item.id
    assert reloaded.state == :ready_to_publish
    assert reloaded.hidden_repository_id == item.hidden_repository_id
    assert reloaded.staged_storage_path == item.staged_storage_path
    assert reloaded.checkpoint == item.checkpoint
    assert reloaded.source_git == item.source_git

    shadow = Repo.get!(Repository, item.hidden_repository_id)
    assert shadow.slug == "import-#{reloaded.id}-#{shadow_suffix(shadow.slug)}"

    assert Repo.aggregate(
             from(mapping in ObjectMapping, where: mapping.repository_item_id == ^reloaded.id),
             :count,
             :id
           ) == 1

    assert Repo.aggregate(
             from(checkpoint in PageCheckpoint,
               where: checkpoint.repository_item_id == ^reloaded.id
             ),
             :count,
             :id
           ) == length(@terminal_resources)

    assert Repo.get!(RepositoryItem, item.id).hidden_repository_id == item.hidden_repository_id
  end

  test "retry rejects corrupt staging evidence", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    item = staged_item!(predecessor, actor, slug: "corrupt-retry")

    Repo.update_all(
      from(candidate in RepositoryItem, where: candidate.id == ^item.id),
      set: [checkpoint: %{"git_staged" => false}]
    )

    assert {:error, :invalid_predecessor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("corrupt-staging")
             )

    refute Repo.exists?(from run in ImportRun, where: run.predecessor_run_id == ^predecessor.id)
  end

  test "retry never copies a one-time envelope and requires a replacement credential", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = terminal_one_time_run!(actor, identity)
    _item = org_item!(run, actor, 9_100_000_020, "one-time-retry", state: :failed)

    assert Repo.get!(ImportRun, run.id).credential_source == :one_time
    assert is_nil(Repo.get!(ImportRun, run.id).credential_ciphertext)

    assert {:ok, successor_view} =
             ForgeImports.retry_import(
               actor,
               run.id,
               saved_source(credential, identity),
               request_metadata("replace-one-time")
             )

    successor = Repo.get!(ImportRun, successor_view.id)
    assert successor.credential_source == :saved
    assert successor.github_credential_id == credential.id
    assert is_nil(successor.credential_ciphertext)
    assert is_nil(successor.credential_nonce)
    assert is_nil(successor.credential_tag)
    assert is_nil(successor.credential_key_id)
    assert is_nil(Repo.get!(ImportRun, run.id).credential_ciphertext)
  end

  test "retry requires an explicit saved credential for saved-source retries", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    _item = org_item!(predecessor, actor, 9_100_000_030, "needs-credential", state: :failed)

    assert {:error, :forbidden} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               %{credential_source: :saved, github_identity_id: identity.id},
               request_metadata("missing-credential")
             )

    assert {:ok, _successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("with-credential")
             )
  end

  test "concurrent retry calls allow only one successor", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    _item = org_item!(predecessor, actor, 9_100_000_040, "concurrent-retry", state: :failed)
    parent = self()
    source = saved_source(credential, identity)
    metadata = request_metadata("concurrent-retry-#{System.unique_integer([:positive])}")

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          send(parent, {:ready, self()})

          receive do
            :go ->
              ForgeImports.retry_import(
                actor,
                predecessor.id,
                source,
                Map.put(metadata, "operation_id", "concurrent-retry-#{index}")
              )
          after
            5_000 -> {:error, :timeout}
          end
        end)
      end

    task_pids = Enum.map(tasks, & &1.pid)

    for pid <- task_pids, do: assert_receive({:ready, ^pid}, 5_000)
    Enum.each(task_pids, &send(&1, :go))

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, fn
             {:error, error} when error in [:invalid_predecessor, :duplicate_successor] -> true
             _ -> false
           end) == 1

    assert Repo.aggregate(
             from(run in ImportRun, where: run.predecessor_run_id == ^predecessor.id),
             :count,
             :id
           ) == 1
  end

  test "predecessor runs and items remain immutable after retry", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :completed_with_warnings)
    item = org_item!(predecessor, actor, 9_100_000_050, "immutable", state: :failed)

    before_run = Repo.get!(ImportRun, predecessor.id)
    before_item = Repo.get!(RepositoryItem, item.id)
    audit_before = Repo.aggregate(AuditEvent, :count, :id)

    assert {:ok, _successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("immutable-predecessor")
             )

    after_run = Repo.get!(ImportRun, predecessor.id)
    after_item = Repo.get!(RepositoryItem, item.id)

    assert before_run.state == after_run.state
    assert before_run.lock_version == after_run.lock_version
    assert before_item.state == after_item.state
    assert before_item.publication_evidence == after_item.publication_evidence
    assert Repo.aggregate(AuditEvent, :count, :id) == audit_before + 1

    audit =
      Repo.one!(
        from event in AuditEvent,
          where: event.action == "github_import.retry_created",
          order_by: [desc: event.id],
          limit: 1
      )

    assert audit.target_type == "github_import_run"
    assert audit.metadata["predecessor_run_id"] == predecessor.id
    refute inspect(audit) =~ "github_pat_"
  end

  test "retry_import masks foreign runs as not_found", %{
    identity: identity,
    credential: credential
  } do
    owner = user_fixture()
    owner_identity = identity_fixture(owner)
    _owner_credential = saved_credential_fixture!(owner, owner_identity)
    predecessor = terminal_org_run!(owner, owner_identity, :failed)
    _item = org_item!(predecessor, owner, 9_100_000_060, "foreign", state: :failed)

    other = user_fixture()

    assert {:error, :not_found} =
             ForgeImports.retry_import(
               other,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("foreign-retry")
             )
  end

  defp terminal_org_run!(actor, identity, terminal_state) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :saved,
        github_credential_id: credential_id(actor, identity),
        source_owner_github_id: identity.github_user_id,
        source_owner_login: identity.login,
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: terminal_state,
        terminal_at: @now,
        selected_count: 1,
        request_metadata: %{}
      }
      |> Persistence.insert_run()
      |> unwrap!()

    run
  end

  defp terminal_one_time_run!(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: identity.github_user_id,
        source_owner_login: identity.login,
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :discovering,
        selected_count: 0,
        request_metadata: %{}
      }
      |> Persistence.insert_run()
      |> unwrap!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @pat,
        @keyring
      )

    run = ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()

    assert {:ok, run} =
             ForgeImports.transition_run(actor, run, :failed, %{terminal_at: @now})

    run
  end

  defp org_item!(run, actor, github_repository_id, slug, overrides \\ []) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/#{slug}",
      source_name: slug,
      source_metadata: %{"archived" => false},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_slug: slug,
      destination_visibility: :private,
      state: :failed,
      publication_evidence: %{},
      attempt_count: 0
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp staged_item!(run, actor, opts) do
    slug = Keyword.fetch!(opts, :slug)
    github_repository_id = System.unique_integer([:positive])

    item =
      org_item!(run, actor, github_repository_id, slug,
        state: :failed,
        attempt_count: 1
      )

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, actor.id, %{
        item_id: item.id,
        generation: 1
      })
      |> Repo.transaction()

    staged_path = ForgeRepos.absolute_storage_path(shadow)

    checkpoint = %{"git_staged" => true, "unsupported_scan" => "complete"}

    source_git = %{
      "empty" => false,
      "default_branch" => "main",
      "refs" => 2,
      "bytes" => 128,
      "lfs_detected" => false,
      "submodules_detected" => false,
      "scan_truncated" => false
    }

    assert {1, _} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 hidden_repository_id: shadow.id,
                 staged_storage_path: staged_path,
                 checkpoint: checkpoint,
                 source_git: source_git,
                 state: :failed
               ]
             )

    item = Repo.get!(RepositoryItem, item.id)

    %ObjectMapping{}
    |> ObjectMapping.create_changeset(%{
      repository_item_id: item.id,
      hidden_repository_id: shadow.id,
      github_repository_id: item.github_repository_id,
      object_kind: "issue",
      github_object_id: 101,
      local_resource_type: "issue",
      local_resource_id: 501
    })
    |> Repo.insert!()

    for resource <- @terminal_resources do
      %PageCheckpoint{}
      |> PageCheckpoint.create_changeset(%{
        repository_item_id: item.id,
        resource_kind: resource,
        page_key: "__terminal_v1__",
        etag: "etag-#{resource}",
        observed_at: @now,
        item_count: 1,
        cursor_metadata: %{},
        committed_at: @now
      })
      |> Repo.insert!()
    end

    item
  end

  defp saved_source(credential, identity) do
    %{
      credential_source: :saved,
      github_credential_id: credential.id,
      github_identity_id: identity.id
    }
  end

  defp credential_id(actor, identity) do
    Repo.one!(
      from credential in GitHubCredential,
        where:
          credential.local_user_id == ^actor.id and credential.github_identity_id == ^identity.id,
        select: credential.id,
        limit: 1
    )
  end

  defp shadow_suffix(slug) do
    case Regex.run(~r/\Aimport-[0-9]+-([0-9a-f]{24})\z/, slug) do
      [_, suffix] -> suffix
      _ -> flunk("unexpected shadow slug #{slug}")
    end
  end

  defp saved_credential_fixture!(actor, identity) do
    case Repo.get_by(GitHubCredential, github_identity_id: identity.id) do
      %GitHubCredential{} = existing -> existing
      nil -> insert_saved_credential!(actor, identity)
    end
  end

  defp insert_saved_credential!(actor, identity) do
    placeholder =
      %GitHubCredential{}
      |> GitHubCredential.changeset(%{
        local_user_id: actor.id,
        github_identity_id: identity.id,
        ciphertext: <<1>>,
        nonce: :binary.copy(<<2>>, 12),
        tag: :binary.copy(<<3>>, 16),
        key_id: "test-v1",
        status: :valid,
        last_verified_at: @now
      })
      |> Repo.insert!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_saved(
        placeholder,
        identity,
        @pat,
        @keyring
      )

    {1, _rows} =
      Repo.update_all(
        from(credential in GitHubCredential, where: credential.id == ^placeholder.id),
        set: [
          ciphertext: envelope.ciphertext,
          nonce: envelope.nonce,
          tag: envelope.tag,
          key_id: envelope.key_id
        ]
      )

    Repo.get!(GitHubCredential, placeholder.id)
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_200_000_000 + suffix,
          login: "retry-#{suffix}",
          avatar_url: nil,
          profile_url: "https://github.com/retry-#{suffix}"
        },
        @now
      )

    case ForgeAccounts.link_github_identity(actor, identity) do
      {:ok, linked} -> linked
      {:error, :already_linked} -> identity
    end
  end

  defp request_metadata(operation_id) do
    %{
      "request_id" => "retry-test-#{System.unique_integer([:positive])}",
      "operation_id" => operation_id,
      "user_agent" => "ExUnit"
    }
  end

  defp user_fixture do
    suffix =
      Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false) <>
        "-#{System.unique_integer([:positive, :monotonic])}"

    Repo.insert!(%User{
      username: "retry-#{suffix}",
      email: "retry-#{suffix}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: flunk("expected success, got #{inspect(reason)}")

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
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
