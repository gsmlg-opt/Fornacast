defmodule FornacastAPI.GitHubWebhookFailureRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)
  use Ecto.Repo, otp_app: :fornacast, adapter: @adapter
end

defmodule FornacastAPI.GitHubWebhookIngressTest do
  use FornacastAPI.ConnCase, async: false

  alias ForgeGitHub.AppConfig
  alias ForgeMirrors.MirrorWebhookDelivery
  alias FornacastAPI.GitHubWebhookFailureRepo

  @path "/api/webhooks/github"
  @secret "webhook-test-secret"

  defmodule ChunkTrackingAdapter do
    @behaviour Plug.Conn.Adapter

    def read_req_body(%{test_pid: test_pid, reads: reads} = state, _opts) do
      if state[:delay_ms], do: Process.sleep(state.delay_ms)
      send(test_pid, {:webhook_body_read, reads + 1})
      {:more, state.chunk, %{state | reads: reads + 1}}
    end

    def send_resp(
          %{delegate: delegate, test_pid: test_pid, reads: reads} = state,
          status,
          headers,
          body
        ) do
      send(test_pid, {:webhook_response_adapter_reads, reads})

      delegate
      |> Plug.Adapters.Test.Conn.send_resp(status, headers, body)
      |> wrap_state(state)
    end

    def send_file(%{delegate: delegate} = state, status, headers, path, offset, length) do
      delegate
      |> Plug.Adapters.Test.Conn.send_file(status, headers, path, offset, length)
      |> wrap_state(state)
    end

    def send_chunked(%{delegate: delegate} = state, status, headers) do
      delegate
      |> Plug.Adapters.Test.Conn.send_chunked(status, headers)
      |> wrap_state(state)
    end

    def chunk(%{delegate: delegate} = state, body) do
      delegate |> Plug.Adapters.Test.Conn.chunk(body) |> wrap_state(state)
    end

    def inform(%{delegate: delegate}, status, headers),
      do: Plug.Adapters.Test.Conn.inform(delegate, status, headers)

    def upgrade(%{delegate: delegate} = state, protocol, opts) do
      case Plug.Adapters.Test.Conn.upgrade(delegate, protocol, opts) do
        {:ok, updated_delegate} -> {:ok, %{state | delegate: updated_delegate}}
        {:error, reason} -> {:error, reason}
      end
    end

    def push(%{delegate: delegate}, path, headers),
      do: Plug.Adapters.Test.Conn.push(delegate, path, headers)

    def get_peer_data(%{delegate: delegate}), do: Plug.Adapters.Test.Conn.get_peer_data(delegate)
    def get_sock_data(%{delegate: delegate}), do: Plug.Adapters.Test.Conn.get_sock_data(delegate)
    def get_ssl_data(%{delegate: delegate}), do: Plug.Adapters.Test.Conn.get_ssl_data(delegate)

    def get_http_protocol(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_http_protocol(delegate)

    defp wrap_state({status, body, updated_delegate}, state) when status in [:ok, :more],
      do: {status, body, %{state | delegate: updated_delegate}}
  end

  setup_all do
    path =
      Path.join(
        System.tmp_dir!(),
        "fornacast-webhook-key-#{System.unique_integer([:positive])}.pem"
      )

    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    File.write!(path, pem, [:binary, :exclusive])
    on_exit(fn -> File.rm(path) end)
    %{private_key_file: path}
  end

  setup %{private_key_file: path} do
    previous_config = Application.get_env(:forge_github, :app_configuration, :disabled)
    previous_inbox = Application.get_env(:fornacast_api, :github_webhook_inbox, :missing)

    config =
      AppConfig.validate!(%{
        app_id: 123,
        app_slug: "fornacast-test",
        private_key_file: path,
        webhook_secret: fn -> @secret end,
        webhook_max_bytes: 1_024
      })

    Application.put_env(:forge_github, :app_configuration, config)
    Application.delete_env(:fornacast_api, :github_webhook_inbox)

    on_exit(fn ->
      Application.put_env(:forge_github, :app_configuration, previous_config)

      case previous_inbox do
        :missing -> Application.delete_env(:fornacast_api, :github_webhook_inbox)
        value -> Application.put_env(:fornacast_api, :github_webhook_inbox, value)
      end
    end)

    :ok
  end

  test "accepts only after byte-exact verification and durable enqueue", %{conn: conn} do
    guid = Ecto.UUID.generate()
    raw = payload("created", 44)

    response = request(conn, raw, delivery: guid)
    assert response.status == 202
    assert JSON.decode!(response.resp_body) == %{"status" => "accepted"}

    delivery = Repo.get_by!(MirrorWebhookDelivery, delivery_guid: guid)
    assert delivery.raw_payload == raw
    assert delivery.event == "installation"
    assert delivery.action == "created"
    assert delivery.hook_id == 9_001
    assert delivery.installation_id == 44
    assert delivery.state == :pending
  end

  test "identical redelivery is 202 while a GUID collision is rejected", %{conn: conn} do
    guid = Ecto.UUID.generate()
    raw = payload("created", 44)

    assert request(conn, raw, delivery: guid).status == 202
    assert request(conn, raw, delivery: guid).status == 202
    assert Repo.aggregate(MirrorWebhookDelivery, :count) == 1

    collision = payload("suspend", 44)
    assert request(conn, collision, delivery: guid).status == 409
    assert Repo.aggregate(MirrorWebhookDelivery, :count) == 1
  end

  test "rejects modified payloads, malformed signed JSON, and oversized bodies", %{conn: conn} do
    raw = payload("created", 44)
    signature = signature(raw)

    assert request(conn, raw <> " ", signature: signature).status == 401
    assert request(conn, ~s({"installation":{"id":44}), event: "installation").status == 400

    config = Application.fetch_env!(:forge_github, :app_configuration)
    Application.put_env(:forge_github, :app_configuration, %{config | webhook_max_bytes: 16})
    assert request(conn, raw).status == 413
  end

  test "requires the dedicated GitHub headers and JSON media type", %{conn: conn} do
    raw = payload("created", 44)

    assert request(conn, raw, content_type: "text/plain").status == 415
    assert request(conn, raw, content_type: "application/json; charset=utf-8").status == 415
    assert request(conn, raw, event: nil).status == 400
    assert request(conn, raw, hook_id: "zero").status == 400
    assert request(conn, raw, user_agent: "ordinary-client").status == 400
    assert request(conn, raw, signature: nil).status == 401
  end

  test "rejects duplicate singleton routing and signature headers", %{conn: conn} do
    raw = payload("created", 44)

    duplicate_event =
      conn
      |> request_headers(raw)
      |> prepend_req_headers([{"x-github-event", "installation"}])
      |> post(@path, raw)

    assert duplicate_event.status == 400

    duplicate_signature =
      build_conn()
      |> request_headers(raw)
      |> prepend_req_headers([{"x-hub-signature-256", signature(raw)}])
      |> post(@path, raw)

    assert duplicate_signature.status == 401
  end

  test "stores deferred supported and ignored combinations without claiming them", %{conn: conn} do
    repository_guid = Ecto.UUID.generate()

    assert request(conn, payload("opened", 44, 99),
             event: "pull_request",
             delivery: repository_guid
           ).status == 202

    assert Repo.get_by!(MirrorWebhookDelivery, delivery_guid: repository_guid).state ==
             :pending_unsupported

    unknown_guid = Ecto.UUID.generate()

    assert request(conn, ~s({"future":"payload"}), event: "future", delivery: unknown_guid).status ==
             202

    ignored = Repo.get_by!(MirrorWebhookDelivery, delivery_guid: unknown_guid)
    assert ignored.state == :ignored
    assert ignored.processed_at
  end

  test "signed issue and comment events enter the durable processing queue", %{conn: conn} do
    for {event, action} <- [{"issues", "edited"}, {"issue_comment", "created"}] do
      guid = Ecto.UUID.generate()
      raw = payload(action, 44, 99)
      assert request(conn, raw, event: event, delivery: guid).status == 202
      delivery = Repo.get_by!(MirrorWebhookDelivery, delivery_guid: guid)
      assert delivery.state == :pending
      assert delivery.raw_payload == raw
      assert delivery.event == event
    end
  end

  test "durable inbox failure returns non-2xx and request path performs no provider call", %{
    conn: conn
  } do
    handler_id = "github-webhook-no-provider-call-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fornacast, :github, :request, :stop],
        fn _event, _measurements, metadata, target ->
          send(target, {:github_api_call, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    delivery_guid = Ecto.UUID.generate()
    failure_repo = start_failure_repo!()

    Ecto.Adapters.SQL.query!(
      failure_repo,
      "select pg_advisory_lock(hashtextextended($1, 0))",
      [delivery_guid]
    )

    Ecto.Adapters.SQL.query!(Repo, "set local lock_timeout = '50ms'", [])

    try do
      refute_received {:github_api_call, _}
      assert request(conn, payload("created", 44), delivery: delivery_guid).status == 503
      refute_received {:github_api_call, _}
    after
      Ecto.Adapters.SQL.query!(
        failure_repo,
        "select pg_advisory_unlock(hashtextextended($1, 0))",
        [delivery_guid]
      )
    end
  end

  test "chunk overflow and total timeout respond through the latest request adapter state" do
    oversized = chunked_conn(String.duplicate("x", 1_025))
    response = FornacastAPI.Plugs.GitHubWebhookRequest.call(oversized, [])
    assert response.status == 413
    assert_received {:webhook_body_read, 1}
    assert_received {:webhook_response_adapter_reads, 1}

    previous_timeout =
      Application.get_env(:fornacast_api, :github_webhook_body_total_timeout_ms, :missing)

    Application.put_env(:fornacast_api, :github_webhook_body_total_timeout_ms, 1)

    on_exit(fn ->
      case previous_timeout do
        :missing ->
          Application.delete_env(:fornacast_api, :github_webhook_body_total_timeout_ms)

        value ->
          Application.put_env(:fornacast_api, :github_webhook_body_total_timeout_ms, value)
      end
    end)

    timed_out = chunked_conn("{}", delay_ms: 5)
    response = FornacastAPI.Plugs.GitHubWebhookRequest.call(timed_out, [])
    assert response.status == 408
    assert_received {:webhook_body_read, 1}
    assert_received {:webhook_response_adapter_reads, 1}
  end

  defp request(conn, raw, options \\ []) do
    delivery = Keyword.get(options, :delivery, Ecto.UUID.generate())
    event = Keyword.get(options, :event, "installation")
    hook_id = Keyword.get(options, :hook_id, "9001")
    user_agent = Keyword.get(options, :user_agent, "GitHub-Hookshot/test")
    content_type = Keyword.get(options, :content_type, "application/json")
    supplied_signature = Keyword.get(options, :signature, signature(raw))

    conn
    |> request_headers(raw,
      content_type: content_type,
      user_agent: user_agent,
      delivery: delivery,
      event: event,
      hook_id: hook_id,
      signature: supplied_signature
    )
    |> post(@path, raw)
  end

  defp request_headers(conn, raw, options \\ []) do
    conn
    |> maybe_header("content-type", Keyword.get(options, :content_type, "application/json"))
    |> maybe_header("user-agent", Keyword.get(options, :user_agent, "GitHub-Hookshot/test"))
    |> maybe_header("x-github-delivery", Keyword.get(options, :delivery, Ecto.UUID.generate()))
    |> maybe_header("x-github-event", Keyword.get(options, :event, "installation"))
    |> maybe_header("x-github-hook-id", Keyword.get(options, :hook_id, "9001"))
    |> maybe_header("x-hub-signature-256", Keyword.get(options, :signature, signature(raw)))
  end

  defp maybe_header(conn, _name, nil), do: conn
  defp maybe_header(conn, name, value), do: put_req_header(conn, name, value)

  defp signature(raw) do
    digest = :crypto.mac(:hmac, :sha256, @secret, raw) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end

  defp payload(action, installation_id, repository_id \\ nil) do
    %{
      "action" => action,
      "installation" => %{"id" => installation_id}
    }
    |> then(fn payload ->
      if repository_id,
        do: Map.put(payload, "repository", %{"id" => repository_id}),
        else: payload
    end)
    |> JSON.encode!()
  end

  defp chunked_conn(chunk, options \\ []) do
    conn = Plug.Adapters.Test.Conn.conn(build_conn(), :post, @path, "")
    {Plug.Adapters.Test.Conn, delegate} = conn.adapter

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("user-agent", "GitHub-Hookshot/test")
      |> put_req_header("x-github-delivery", Ecto.UUID.generate())
      |> put_req_header("x-github-event", "installation")
      |> put_req_header("x-github-hook-id", "9001")
      |> put_req_header("x-hub-signature-256", String.duplicate("0", 64) |> then(&"sha256=#{&1}"))

    state = %{
      delegate: delegate,
      test_pid: self(),
      reads: 0,
      chunk: chunk,
      delay_ms: Keyword.get(options, :delay_ms)
    }

    %{conn | adapter: {ChunkTrackingAdapter, state}}
  end

  defp start_failure_repo! do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)

    start_supervised!({GitHubWebhookFailureRepo, config})
    GitHubWebhookFailureRepo
  end
end
