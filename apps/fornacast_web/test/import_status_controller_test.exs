defmodule FornacastWeb.ImportStatusControllerTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias ForgeAccounts.{GitHubCredential, User}
  alias ForgeImports.{Persistence, RepositoryItem}
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint
  @now ~U[2026-08-25 10:00:00Z]
  @retry_at ~U[2026-08-25 11:00:00Z]

  setup do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    actor = user_fixture("import-status")
    identity = identity_fixture(actor)
    credential = saved_credential_fixture!(actor, identity)

    run =
      running_org_run!(actor, identity, credential,
        destination_organization_slug: "acme-local",
        selected_count: 2
      )

    alpha = item_fixture!(run, 9_000_000_201, "octo/alpha", "alpha", state: :staging_git)
    beta = item_fixture!(run, 9_000_000_202, "octo/beta", "beta", state: :published)

    %{
      actor: actor,
      identity: identity,
      credential: credential,
      run: run,
      alpha: alpha,
      beta: beta
    }
  end

  test "returns safe bounded JSON for the authenticated owner", %{actor: actor, run: run} do
    conn = request_conn(actor) |> get("/imports/#{run.id}/status")
    body = json_response(conn, 200)

    assert body["state"] == "running"
    assert body["poll"] == true
    assert body["terminal"] == false
    assert body["counts"]["selected"] == 2
    assert body["counts"]["published"] == 0
    assert is_list(body["repositories"])
    assert length(body["repositories"]) == 2

    [alpha, beta] = body["repositories"]
    assert alpha["source_full_name"] == "octo/alpha"
    assert alpha["state"] == "staging_git"
    assert beta["source_full_name"] == "octo/beta"
    assert beta["state"] == "published"
    assert beta["published_href"] == "/acme-local/beta"

    refute inspect(body) =~ "credential_ciphertext"
    refute inspect(body) =~ "github_pat_"
    refute inspect(body) =~ "storage_path"
    refute inspect(body) =~ "credential_envelope"
    assert_private_no_store(conn)
  end

  test "masks foreign runs as not found", %{run: run} do
    other = user_fixture("import-status-foreign")

    conn = request_conn(other) |> get("/imports/#{run.id}/status")
    assert json_response(conn, 404) == %{"error" => "not_found"}
    assert_private_no_store(conn)
  end

  test "includes rate-limit resume time in status JSON", %{actor: actor, run: run, alpha: alpha} do
    assert {:ok, waiting} = ForgeImports.Waits.rate_limited(alpha, @retry_at, :secondary)
    assert waiting.next_attempt_at == @retry_at

    body =
      request_conn(actor)
      |> get("/imports/#{run.id}/status")
      |> json_response(200)

    repo = Enum.find(body["repositories"], &(&1["id"] == waiting.id))
    assert repo["wait_reason"] == "rate_limit"
    assert repo["next_attempt_at"] == DateTime.to_iso8601(@retry_at)
  end

  test "requires an authenticated session", %{run: run} do
    conn = build_conn() |> get("/imports/#{run.id}/status")
    assert redirected_to(conn) == "/login"
  end

  test "rejects invalid run ids", %{actor: actor} do
    conn = request_conn(actor) |> get("/imports/not-a-number/status")
    assert json_response(conn, 404) == %{"error" => "not_found"}
  end

  defp request_conn(user) do
    conn =
      build_conn()
      |> put_req_header("user-agent", "import-status-controller-test")

    Plug.Test.init_test_session(conn, user_id: user.id)
  end

  defp assert_private_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp running_org_run!(actor, identity, credential, overrides \\ []) do
    attrs =
      %{
        actor_user_id: actor.id,
        source_kind: :organization,
        source_owner_github_id: 8_001,
        source_owner_login: "octo",
        destination_organization_action: :new,
        destination_organization_slug: "acme-local",
        destination_organization_status: :clean,
        github_identity_id: identity.id,
        github_credential_id: credential.id,
        credential_source: :saved,
        state: :running,
        selected_count: 1,
        published_count: 0,
        skipped_count: 0,
        warning_count: 0,
        failure_count: 0,
        request_metadata: request_metadata()
      }
      |> Map.merge(Map.new(overrides))

    Persistence.insert_run(attrs) |> unwrap!()
  end

  defp item_fixture!(run, github_repository_id, full_name, slug, overrides \\ []) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: full_name,
      source_name: slug,
      source_metadata: %{"default_branch" => "main"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: run.actor_user_id,
      destination_slug: slug,
      destination_visibility: :private,
      state: :queued,
      publication_evidence: %{},
      imported_count: 0,
      skipped_count: 0,
      warning_count: 0,
      failure_count: 0,
      attempt_count: 0
    }

    target_state = Keyword.get(overrides, :state, :queued)

    item =
      defaults
      |> Map.merge(Map.new(overrides))
      |> Map.put(:state, :queued)
      |> Map.put(:publication_evidence, %{})
      |> Persistence.insert_repository_item()
      |> unwrap!()

    if target_state == :queued do
      item
    else
      assert {1, _} =
               Repo.update_all(
                 from(candidate in RepositoryItem, where: candidate.id == ^item.id),
                 set: [state: target_state]
               )

      Repo.get!(RepositoryItem, item.id)
    end
  end

  defp saved_credential_fixture!(actor, identity) do
    case Repo.get_by(GitHubCredential, github_identity_id: identity.id) do
      %GitHubCredential{} = existing -> existing
      nil -> insert_saved_credential!(actor, identity)
    end
  end

  defp insert_saved_credential!(actor, identity) do
    %GitHubCredential{}
    |> GitHubCredential.changeset(%{
      local_user_id: actor.id,
      github_identity_id: identity.id,
      ciphertext: <<1>>,
      nonce: :binary.copy(<<2>>, 12),
      tag: :binary.copy(<<3>>, 16),
      key_id: "test-v1",
      status: :valid
    })
    |> Repo.insert!()
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_100_000_000 + suffix,
          login: "status-#{suffix}",
          avatar_url: nil,
          profile_url: "https://github.com/status-#{suffix}"
        },
        @now
      )

    case ForgeAccounts.link_github_identity(actor, identity) do
      {:ok, linked} -> linked
      {:error, :already_linked} -> identity
    end
  end

  defp request_metadata do
    %{
      "request_id" => "status-test-#{System.unique_integer([:positive])}",
      "operation_id" => "status-op-#{System.unique_integer([:positive])}",
      "user_agent" => "ExUnit"
    }
  end

  defp user_fixture(prefix) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Repo.insert!(%User{
      username: "#{prefix}-#{suffix}",
      email: "#{prefix}-#{suffix}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp unwrap!({:ok, value}), do: value

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
