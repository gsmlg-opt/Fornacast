defmodule ForgeImports.TelemetryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, User}
  alias ForgeImports.GitHub.Client
  alias ForgeImports.{Cancellation, Persistence, Waits}
  alias Fornacast.Repo

  @now ~U[2026-08-25 10:00:00Z]
  @retry_at ~U[2026-08-25 11:00:00Z]
  @pat "github_pat_telemetry_test_secret"

  @telemetry_events [
    [:fornacast, :github_import, :phase, :stop],
    [:fornacast, :github_import, :github, :request, :stop],
    [:fornacast, :github_import, :rate_limit, :pause],
    [:fornacast, :github_import, :cancel, :requested],
    [:fornacast, :github_import, :cleanup, :stop],
    [:fornacast, :github_import, :run, :completed],
    [:fornacast, :github_import, :publication, :stop],
    [:fornacast, :github_import, :git, :staged],
    [:fornacast, :github_import, :retry, :created]
  ]

  setup :attach_telemetry_handlers

  describe "bounded metadata and github client" do
    setup {Req.Test, :verify_on_exit!}

    test "bounded drops names, usernames, urls, paths, tokens, headers, bodies, and exception text" do
      sensitive = %{
        run_id: 42,
        item_id: 7,
        phase: :staging_git,
        owner_login: "octocat",
        repository_name: "hello-world",
        url: "https://api.github.com/repos/octocat/hello-world",
        path: "/tmp/import/staging/shadow.git",
        authorization: "Bearer github_pat_secret_value",
        pat: "github_pat_secret_value",
        body: ~s({"login":"octocat"}),
        exception: "RuntimeError: mirror fetch failed for /secret/path",
        username: "alice",
        slug: "private-repo",
        request_metadata: %{"request_id" => "github_pat_leak"}
      }

      bounded = ForgeImports.Telemetry.bounded(sensitive)

      assert bounded == %{run_id: 42, item_id: 7, phase: :staging_git}
      refute inspect(bounded) =~ "octocat"
      refute inspect(bounded) =~ "github_pat_"
      refute inspect(bounded) =~ "Bearer"
      refute inspect(bounded) =~ "/tmp/"
      refute inspect(bounded) =~ "RuntimeError"
    end

    test "execute emits under the github_import namespace with bounded metadata only" do
      assert :ok =
               ForgeImports.Telemetry.execute(
                 [:phase, :stop],
                 %{duration: 12},
                 %{
                   run_id: 9,
                   item_id: 3,
                   phase: :staging_git,
                   outcome: :ok,
                   owner_login: "must-drop"
                 }
               )

      assert_receive {:telemetry, [:fornacast, :github_import, :phase, :stop], measurements,
                      metadata}

      assert measurements == %{duration: 12}
      assert metadata == %{run_id: 9, item_id: 3, phase: :staging_git, outcome: :ok}
      refute inspect({measurements, metadata}) =~ "must-drop"
    end

    test "github client request telemetry records outcome without transport secrets" do
      stub = stub_name()

      Req.Test.expect(stub, fn conn ->
        assert conn.request_path == "/user"
        Req.Test.json(conn, user_json())
      end)

      assert {:ok, _user} = Client.authenticated_user(@pat, client_opts(stub))

      assert_receive {:telemetry, [:fornacast, :github_import, :github, :request, :stop],
                      measurements, metadata}

      assert is_integer(measurements.duration) and measurements.duration >= 0
      assert metadata.outcome == :ok
      refute Map.has_key?(metadata, :authorization)
      refute inspect({measurements, metadata}) =~ "github_pat_"
    end

    test "github client rate-limit telemetry records classification without retry timestamps" do
      stub = stub_name()

      Req.Test.expect(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", "1893456000")
        |> Plug.Conn.send_resp(403, ~s({"message":"rate limit"}))
      end)

      assert {:error, %ForgeImports.GitHub.Error{kind: :primary_rate_limit}} =
               Client.authenticated_user(@pat, client_opts(stub))

      assert_receive {:telemetry, [:fornacast, :github_import, :github, :request, :stop], _req,
                      %{outcome: :error, error: :primary_rate_limit}}

      assert_receive {:telemetry, [:fornacast, :github_import, :rate_limit, :pause], %{count: 1},
                      metadata}

      assert metadata.classification == :primary
      assert metadata.error == :primary_rate_limit
      refute inspect(metadata) =~ "1893456000"
    end
  end

  describe "import lifecycle telemetry" do
    setup :import_fixtures

    test "waits, cancellation, and cleanup emit bounded telemetry", %{
      actor: actor,
      run: run,
      item: item
    } do
      assert {:ok, waiting} = Waits.rate_limited(item, @retry_at, :secondary)
      assert waiting.wait_reason == "rate_limit"

      assert_receive {:telemetry, [:fornacast, :github_import, :rate_limit, :pause], %{count: 1},
                      wait_metadata}

      assert wait_metadata == %{
               item_id: item.id,
               run_id: run.id,
               phase: :staging_git,
               classification: :secondary
             }

      assert {:ok, requested} =
               Cancellation.request(actor, run, request_metadata("cancel-telemetry"), now: @now)

      assert requested.state == :cancel_requested

      assert_receive {:telemetry, [:fornacast, :github_import, :cancel, :requested], %{count: 1},
                      cancel_metadata}

      assert cancel_metadata == %{run_id: run.id, canceled: true}
      refute inspect(cancel_metadata) =~ "github_pat_"

      now = DateTime.utc_now(:second)
      deadline = System.monotonic_time() + 1_000

      assert :none =
               ForgeImports.RepositoryCleanup.reconcile_kind(:remote_quarantine, now, deadline)

      assert_receive {:telemetry, [:fornacast, :github_import, :cleanup, :stop], measurements,
                      cleanup_metadata}

      assert is_integer(measurements.duration) and measurements.duration >= 0
      assert cleanup_metadata == %{cleanup_kind: :remote_quarantine, outcome: :none}
      refute inspect(cleanup_metadata) =~ "/"
    end
  end

  defp attach_telemetry_handlers(_context) do
    handler = {__MODULE__, make_ref()}

    for event <- @telemetry_events do
      :ok =
        :telemetry.attach(
          {handler, event},
          event,
          fn attached_event, measurements, metadata, _config ->
            send(self(), {:telemetry, attached_event, measurements, metadata})
          end,
          nil
        )
    end

    on_exit(fn ->
      for event <- @telemetry_events do
        :telemetry.detach({handler, event})
      end
    end)

    :ok
  end

  defp import_fixtures(_context) do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      ForgeImports.RecoveryTestHelper.mark_sandbox_owner!()
    end

    Application.put_env(:fornacast, :github_credential_keyring, %{
      active: "test-2026-08-25",
      keys: %{"test-2026-08-25" => :binary.copy(<<42>>, 32)}
    })

    assert :ok = ForgeAccounts.GitHubCredentialVault.ready?()

    actor = user_fixture()
    identity = identity_fixture(actor)
    credential = saved_credential_fixture!(actor, identity)
    run = running_run!(actor, %{identity_id: identity.id}, credential)
    item = staging_git_item!(run, actor)

    %{actor: actor, run: run, item: item}
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}

  defp client_opts(stub, key_id \\ 1) do
    [
      gate_key: {:saved_credential, key_id},
      plug: {Req.Test, stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
      now: fn -> @now end
    ]
  end

  defp user_json do
    %{
      "id" => 9_000_000_001,
      "login" => "octocat",
      "name" => "The Octocat",
      "avatar_url" => "https://avatars.githubusercontent.com/u/9",
      "html_url" => "https://github.com/octocat"
    }
  end

  defp user_fixture do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Repo.insert!(%User{
      username: "telemetry-#{suffix}",
      email: "telemetry-#{suffix}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_100_000_000 + suffix,
          login: "telemetry-#{suffix}",
          avatar_url: nil,
          profile_url: "https://github.com/telemetry-#{suffix}"
        },
        @now
      )

    case ForgeAccounts.link_github_identity(actor, identity) do
      {:ok, linked} -> linked
      {:error, :already_linked} -> identity
    end
  end

  defp saved_credential_fixture!(actor, identity) do
    case Repo.get_by(GitHubCredential, github_identity_id: identity.id) do
      %GitHubCredential{} = existing ->
        existing

      nil ->
        insert_saved_credential!(actor, identity)
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
        key_id: "test-2026-08-25",
        status: :valid,
        last_verified_at: @now
      })
      |> Repo.insert!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_saved(
        placeholder,
        identity,
        @pat,
        Application.fetch_env!(:fornacast, :github_credential_keyring)
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

  defp running_run!(actor, %{identity_id: identity_id}, credential) do
    %{
      actor_user_id: actor.id,
      source_kind: :repository,
      github_identity_id: identity_id,
      credential_source: :saved,
      github_credential_id: credential.id,
      source_owner_github_id: 9_000_000_201,
      source_owner_login: "acme",
      source_repository_github_id: 9_200_000_200,
      source_repository_full_name: "acme/demo",
      destination_organization_action: :existing,
      destination_organization_slug: actor.username,
      destination_organization_status: :clean,
      state: :running,
      selected_count: 1,
      request_metadata: request_metadata("run")
    }
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp staging_git_item!(run, actor, github_repository_id \\ 9_200_000_040) do
    shadow = importing_shadow_fixture!(actor)

    Persistence.insert_repository_item(%{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{"default_branch" => "main", "visibility" => "private"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: "demo-telemetry",
      destination_visibility: :private,
      state: :staging_git,
      hidden_repository_id: shadow.id,
      staged_storage_path: ForgeRepos.absolute_storage_path(shadow),
      attempt_count: 1
    })
    |> unwrap!()
  end

  defp importing_shadow_fixture!(actor) do
    {:ok, shadow} =
      ForgeRepos.create_repository(actor, %{
        slug: "shadow-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}",
        name: "shadow",
        visibility: :private
      })

    shadow
    |> Ecto.Changeset.change(lifecycle: :importing)
    |> Repo.update!()
  end

  defp request_metadata(operation_id) do
    %{
      "request_id" => "telemetry-test-#{System.unique_integer([:positive])}",
      "operation_id" => operation_id || "telemetry-op-#{System.unique_integer([:positive])}",
      "user_agent" => "ExUnit"
    }
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: flunk("expected success, got #{inspect(reason)}")

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
