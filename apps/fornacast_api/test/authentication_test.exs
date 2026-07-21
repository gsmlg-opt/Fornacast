defmodule FornacastAPI.AuthenticationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForgeAccounts.User
  alias Fornacast.Repo

  @endpoint FornacastAPI.Endpoint
  @user_agent {"user-agent", "fornacast-contract-test/1.0"}
  @authentication_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/authentication/authenticating-to-the-rest-api"

  defp put_req_header(conn, {name, value}), do: put_req_header(conn, name, value)

  setup do
    reset_database!()

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "alice",
        email: "alice-api-auth@example.com",
        password: "correct horse battery staple"
      })

    {:ok, api_key, secret} =
      ForgeAccounts.create_api_key(user, %{
        name: "REST API",
        scopes: ["repo", "write:org"]
      })

    %{api_key: api_key, secret: secret, user: user}
  end

  test "accepts Bearer and token schemes case-insensitively", %{
    api_key: api_key,
    secret: secret
  } do
    for scheme <- ["Bearer", "token", "bEaReR", "ToKeN"] do
      conn =
        api_conn()
        |> put_req_header("authorization", "#{scheme} #{secret}")
        |> get("/api/v3/user")

      assert %{
               "login" => "alice",
               "email" => "alice-api-auth@example.com",
               "type" => "User",
               "private_gists" => 0
             } = json_response(conn, 200)

      assert get_resp_header(conn, "x-oauth-scopes") == ["repo, write:org"]
    end

    assert Repo.reload!(api_key).last_used_at
  end

  test "endpoint telemetry omits raw authorization credentials", %{secret: secret} do
    events = [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]]
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    conn =
      api_conn()
      |> put_req_header("authorization", "Bearer #{secret}")
      |> get("/api/v3/user")

    assert %{
             "login" => "alice",
             "email" => "alice-api-auth@example.com",
             "type" => "User",
             "private_gists" => 0
           } = json_response(conn, 200)

    for event <- events do
      {measurements, %{conn: %Plug.Conn{} = telemetry_conn, options: []} = metadata} =
        receive_endpoint_event(event)

      raw_authorization_visible? = telemetry_metadata_contains_secret?(metadata, secret)
      refute raw_authorization_visible?
      assert get_req_header(telemetry_conn, "authorization") == []
      assert telemetry_conn.method == "GET"
      assert telemetry_conn.request_path == "/api/v3/user"
      assert_endpoint_measurements(event, measurements)
    end

    duplicate_secrets = ["fc_pat_duplicate_header_probe_one", "fc_pat_duplicate_header_probe_two"]
    [first_secret, second_secret] = duplicate_secrets

    duplicate =
      api_conn()
      |> Map.update!(:req_headers, fn headers ->
        [
          {"Authorization", "Bearer #{first_secret}"},
          {"authorization", "token #{second_secret}"}
          | headers
        ]
      end)
      |> get("/api/v3/users/alice")

    assert duplicate.status == 401

    for event <- events do
      {_measurements, %{conn: %Plug.Conn{} = telemetry_conn} = metadata} =
        receive_endpoint_event(event)

      raw_authorization_visible? =
        Enum.any?(duplicate_secrets, &telemetry_metadata_contains_secret?(metadata, &1))

      authorization_header_visible? = telemetry_authorization_header?(telemetry_conn)

      refute raw_authorization_visible?
      refute authorization_header_visible?
    end
  end

  test "leaves optional authentication empty when credentials are absent" do
    public = api_conn() |> get("/api/v3/users/alice")

    assert %{"login" => "alice", "email" => nil, "type" => "User", "public_repos" => 0} =
             json_response(public, 200)

    versions = api_conn() |> get("/api/v3/versions")
    assert json_response(versions, 200) == ["2022-11-28", "2026-03-10"]
    assert get_resp_header(versions, "x-oauth-scopes") == [""]

    required = api_conn() |> get("/api/v3/user")
    assert json_response(required, 401)["message"] == "Bad credentials"
  end

  test "rejects malformed and multiple Authorization headers", %{secret: secret} do
    malformed_headers = [
      "Bearer",
      "Bearer #{secret} trailing",
      "Bearer #{secret} ",
      " Bearer #{secret}",
      "Basic #{secret}",
      "token\t"
    ]

    for authorization <- malformed_headers do
      conn =
        api_conn()
        |> put_req_header("authorization", authorization)
        |> get("/api/v3/users/alice")

      assert_bad_credentials(conn, secret)
    end

    multiple =
      api_conn()
      |> Map.update!(:req_headers, fn headers ->
        [
          {"authorization", "Bearer #{secret}"},
          {"authorization", "token #{secret}"}
          | headers
        ]
      end)
      |> get("/api/v3/users/alice")

    assert_bad_credentials(multiple, secret)
  end

  test "rejects invalid and wrong-prefix tokens even on public routes", %{secret: secret} do
    wrong_prefix_secret = String.replace_prefix(secret, "fc_pat_", "wrong__")

    credentials = [
      {"Bearer fc_pat_invalid", "fc_pat_invalid"},
      {"Bearer ghp_invalid", "ghp_invalid"},
      {"token #{wrong_prefix_secret}", wrong_prefix_secret}
    ]

    for {authorization, rejected_secret} <- credentials do
      conn =
        api_conn()
        |> put_req_header("authorization", authorization)
        |> get("/api/v3/users/alice")

      assert_bad_credentials(conn, rejected_secret)
    end
  end

  test "rejects a terminal newline after an otherwise valid token", %{
    api_key: api_key,
    secret: secret
  } do
    conn =
      api_conn()
      |> Map.update!(:req_headers, fn headers ->
        [{"authorization", "Bearer #{secret}\n"} | headers]
      end)
      |> get("/api/v3/user")

    assert_bad_credentials(conn, secret)
    assert is_nil(Repo.reload!(api_key).last_used_at)
  end

  test "rejects revoked and expired tokens without recording use", %{user: user} do
    {:ok, revoked_key, revoked_secret} =
      ForgeAccounts.create_api_key(user, %{name: "revoked", scopes: ["repo"]})

    assert {:ok, _revoked_key} = ForgeAccounts.revoke_api_key(user, revoked_key.id)

    {:ok, expired_key, expired_secret} =
      ForgeAccounts.create_api_key(user, %{
        name: "expired",
        scopes: ["repo"],
        expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      })

    for secret <- [revoked_secret, expired_secret] do
      conn =
        api_conn()
        |> put_req_header("authorization", "Bearer #{secret}")
        |> get("/api/v3/user")

      assert_bad_credentials(conn, secret)
    end

    assert is_nil(Repo.reload!(revoked_key).last_used_at)
    assert is_nil(Repo.reload!(expired_key).last_used_at)
  end

  test "rejects tokens owned by disabled users", %{api_key: api_key, secret: secret, user: user} do
    assert {:ok, _disabled_user} =
             user
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    conn =
      api_conn()
      |> put_req_header("authorization", "token #{secret}")
      |> get("/api/v3/user")

    assert_bad_credentials(conn, secret)
    assert is_nil(Repo.reload!(api_key).last_used_at)
  end

  defp assert_bad_credentials(conn, rejected_secret) do
    refute response_contains_secret?(conn.resp_body, rejected_secret)
    assert conn.status == 401

    body = JSON.decode!(conn.resp_body)
    refute response_contains_secret?(inspect(body), rejected_secret)

    assert body == %{
             "documentation_url" => @authentication_documentation_url,
             "message" => "Bad credentials"
           }

    assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
    assert get_resp_header(conn, "x-github-media-type") == ["github.v3; format=json"]
    assert [request_id] = get_resp_header(conn, "x-github-request-id")
    assert request_id != ""
  end

  defp response_contains_secret?(response, secret), do: String.contains?(response, secret)

  defp telemetry_metadata_contains_secret?(metadata, secret),
    do: metadata |> inspect() |> String.contains?(secret)

  defp telemetry_authorization_header?(conn) do
    Enum.any?(conn.req_headers, fn {name, _value} ->
      String.downcase(name) == "authorization"
    end)
  end

  defp receive_endpoint_event(event) do
    receive do
      {^event, measurements, metadata} -> {measurements, metadata}
    after
      1_000 -> flunk("endpoint telemetry event was not emitted")
    end
  end

  defp assert_endpoint_measurements([:phoenix, :endpoint, :start], measurements) do
    assert %{system_time: system_time} = measurements
    assert is_integer(system_time)
  end

  defp assert_endpoint_measurements([:phoenix, :endpoint, :stop], measurements) do
    assert %{duration: duration} = measurements
    assert is_integer(duration)
  end

  defp api_conn, do: build_conn() |> put_req_header(@user_agent)

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(["api_keys", "users"], &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", []))
    end
  end
end
