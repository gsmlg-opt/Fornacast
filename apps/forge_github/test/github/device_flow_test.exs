defmodule ForgeGitHub.DeviceFlowTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.DeviceFlow

  setup {Req.Test, :verify_on_exit!}

  test "starts at GitHub with offline access and redacts the device code" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      assert_request(conn, "/login/device/code", %{
        "client_id" => "fixture-client",
        "scope" => "offline_access"
      })

      Req.Test.json(conn, authorization())
    end)

    assert {:ok, value} = DeviceFlow.start(options(stub))
    assert value.device_code == "device-secret"
    assert value.user_code == "ABCD-EFGH"
    assert value.verification_uri == "https://github.com/login/device"
    assert value.expires_in == 900
    assert value.interval == 5
    refute inspect(value) =~ "device-secret"
  end

  test "polls once and returns client-bound expiring tokens with redacted inspection" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      assert_request(conn, "/login/oauth/access_token", %{
        "client_id" => "fixture-client",
        "device_code" => "device-secret",
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
      })

      Req.Test.json(conn, tokens())
    end)

    before = DateTime.utc_now()
    assert {:ok, value} = DeviceFlow.poll("device-secret", options(stub))
    assert value.client_id == "fixture-client"
    assert value.access_token == "access-secret"
    assert value.refresh_token == "refresh-secret"
    assert DateTime.diff(value.expires_at, before) in 28_799..28_801
    assert DateTime.diff(value.refresh_expires_at, before) in 15_897_599..15_897_601
    refute inspect(value) =~ "access-secret"
    refute inspect(value) =~ "refresh-secret"
  end

  test "refreshes without a client secret and preserves the original client binding" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      assert_request(conn, "/login/oauth/access_token", %{
        "client_id" => "original-client",
        "refresh_token" => "refresh-secret",
        "grant_type" => "refresh_token"
      })

      Req.Test.json(conn, tokens())
    end)

    assert {:ok, %{client_id: "original-client"}} =
             DeviceFlow.refresh(
               "refresh-secret",
               Keyword.put(options(stub), :client_id, "original-client")
             )
  end

  test "maps expected provider failures without retaining descriptions or secret material" do
    for reason <-
          ~w(authorization_pending access_denied device_flow_disabled expired_token bad_refresh_token incorrect_client_credentials incorrect_device_code unsupported_grant_type) do
      stub = stub()

      Req.Test.expect(
        stub,
        &Req.Test.json(&1, %{"error" => reason, "error_description" => "access-secret"})
      )

      assert {:error, error} = DeviceFlow.poll("device-secret", options(stub))
      assert error == String.to_existing_atom(reason)
      refute inspect(error) =~ "access-secret"
    end

    stub = stub()
    Req.Test.expect(stub, &Req.Test.json(&1, %{"error" => "slow_down", "interval" => 10}))
    assert {:error, {:slow_down, 10}} = DeviceFlow.poll("device-secret", options(stub))

    stub = stub()
    Req.Test.expect(stub, &Req.Test.json(&1, %{"error" => "bad_refresh_token"}))
    assert {:error, :bad_refresh_token} = DeviceFlow.refresh("refresh-secret", options(stub))
  end

  test "rejects malformed authorization, untrusted links and invalid authorization timing" do
    for response <- [
          Map.delete(authorization(), "device_code"),
          Map.put(authorization(), "device_code", " "),
          Map.put(authorization(), "user_code", ""),
          Map.put(authorization(), "verification_uri", "https://attacker.example/login/device"),
          Map.put(
            authorization(),
            "verification_uri",
            "https://github.com.attacker.example/login/device"
          ),
          Map.put(authorization(), "verification_uri", "https://user@github.com/login/device"),
          Map.put(authorization(), "verification_uri", "http://github.com/login/device"),
          Map.put(
            authorization(),
            "verification_uri",
            "https://github.com/login/device?code=secret"
          ),
          Map.put(authorization(), "expires_in", 0),
          Map.put(authorization(), "expires_in", 86_401),
          Map.put(authorization(), "interval", -1),
          Map.put(authorization(), "interval", 901)
        ] do
      stub = stub()
      Req.Test.expect(stub, &Req.Test.json(&1, response))
      assert {:error, :invalid_response} = DeviceFlow.start(options(stub))
    end
  end

  test "rejects token responses without refresh material or bounded positive TTLs" do
    for response <- [
          Map.delete(tokens(), "refresh_token"),
          Map.put(tokens(), "access_token", ""),
          Map.put(tokens(), "token_type", "mac"),
          Map.put(tokens(), "expires_in", "28800"),
          Map.put(tokens(), "expires_in", -1),
          Map.put(tokens(), "expires_in", 31_536_001),
          Map.put(tokens(), "refresh_token_expires_in", 0),
          Map.put(tokens(), "refresh_token_expires_in", 31_536_001),
          Map.put(tokens(), "refresh_token_expires_in", 10)
        ] do
      stub = stub()
      Req.Test.expect(stub, &Req.Test.json(&1, response))
      assert {:error, :invalid_response} = DeviceFlow.poll("device-secret", options(stub))
    end
  end

  test "rejects oversized JSON, malformed JSON, unknown errors and malformed slow-down" do
    for body <- [
          String.duplicate("x", 65_537),
          "{bad-json",
          "[]",
          JSON.encode!(%{"error" => "access-secret"}),
          JSON.encode!(%{"error" => "slow_down"}),
          JSON.encode!(%{"error" => "slow_down", "interval" => 0})
        ] do
      stub = stub()
      Req.Test.expect(stub, &Plug.Conn.send_resp(&1, 200, body))
      assert {:error, error} = DeviceFlow.poll("device-secret", options(stub))
      assert error in [:invalid_response, :response_too_large]
    end
  end

  test "does not follow redirects, retry provider failures or expose their bodies" do
    for status <- [302, 429, 500, 503] do
      stub = stub()

      Req.Test.expect(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.example/steal")
        |> Plug.Conn.send_resp(status, "access-secret")
      end)

      assert {:error, :provider_unavailable} = DeviceFlow.refresh("refresh-secret", options(stub))
    end
  end

  test "accepts OAuth errors on HTTP failure but never accepts credentials on HTTP failure" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "device_flow_disabled"})
    end)

    assert {:error, :device_flow_disabled} = DeviceFlow.start(options(stub))

    stub = stub()

    Req.Test.expect(stub, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(tokens())
    end)

    assert {:error, :invalid_response} = DeviceFlow.poll("device-secret", options(stub))
  end

  test "counts response chunks through exactly 64 KiB and rejects one byte more" do
    body = String.trim_trailing(JSON.encode!(tokens()), "}") <> ~s(,"padding":""})
    prefix = String.slice(body, 0, byte_size(body) - 2)
    suffix = ~s("})
    padding = String.duplicate("x", 65_536 - byte_size(body))

    for {tail, expected} <- [{"", :ok}, {"x", :response_too_large}] do
      stub = stub()

      Req.Test.expect(stub, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, prefix)
        {:ok, conn} = Plug.Conn.chunk(conn, padding)
        {:ok, conn} = Plug.Conn.chunk(conn, tail <> suffix)
        conn
      end)

      case expected do
        :ok -> assert {:ok, _token} = DeviceFlow.poll("device-secret", options(stub))
        error -> assert {:error, ^error} = DeviceFlow.poll("device-secret", options(stub))
      end
    end
  end

  test "establishes caller monitoring before starting a refresh request" do
    stub = stub()
    caller = self()

    Req.Test.expect(stub, fn conn ->
      {:monitors, monitors} = Process.info(self(), :monitors)
      send(caller, {:request_start_monitors, monitors})
      Req.Test.json(conn, tokens())
    end)

    assert {:ok, _token} = DeviceFlow.refresh("refresh-secret", options(stub))
    assert_receive {:request_start_monitors, monitors}
    assert {:process, caller} in monitors
  end

  test "stops a blocked request when its caller exits" do
    stub = stub()
    owner = self()

    Req.Test.stub(stub, fn conn ->
      send(owner, {:blocked_request, self()})

      receive do
        :finish -> Req.Test.json(conn, tokens())
      end
    end)

    caller =
      spawn(fn ->
        receive do
          :start -> DeviceFlow.poll("device-secret", options(stub))
        end
      end)

    Req.Test.allow(stub, self(), caller)
    send(caller, :start)
    assert_receive {:blocked_request, worker}
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "sanitizes transport exceptions and enforces a total request timeout" do
    stub = stub()
    Req.Test.expect(stub, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :timeout} = DeviceFlow.start(options(stub))

    stub = stub()
    Req.Test.expect(stub, fn _conn -> raise "refresh-secret" end)
    assert {:error, :transport_error} = DeviceFlow.refresh("refresh-secret", options(stub))

    stub = stub()
    owner = self()

    Req.Test.expect(stub, fn conn ->
      send(owner, {:request_worker, self()})
      Process.sleep(10_000)
      Req.Test.json(conn, tokens())
    end)

    assert {:error, :timeout} =
             DeviceFlow.poll("device-secret", Keyword.put(options(stub), :request_timeout, 50))

    assert_receive {:request_worker, worker}
    refute Process.alive?(worker)
  end

  test "rejects invalid request values before sending HTTP" do
    stub = stub()
    Req.Test.stub(stub, fn _ -> flunk("invalid request reached provider") end)

    for value <- [nil, "", " ", String.duplicate("x", 4097)] do
      assert {:error, :invalid_request} = DeviceFlow.poll(value, options(stub))
      assert {:error, :invalid_request} = DeviceFlow.refresh(value, options(stub))
    end

    for client <- [nil, "", " ", String.duplicate("x", 257)] do
      assert {:error, :invalid_request} =
               DeviceFlow.start(Keyword.put(options(stub), :client_id, client))
    end
  end

  test "reads the configured default public client ID" do
    assert DeviceFlow.client_id() ==
             Application.get_env(:forge_github, :device_client_id, "Iv23lizCVE3E24s7fCA0")
  end

  defp assert_request(conn, path, params) do
    assert conn.method == "POST"
    assert conn.scheme == :https
    assert conn.host == "github.com"
    assert conn.port == 443
    assert conn.request_path == path
    assert conn.query_string == ""
    assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
    assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
    assert content_type =~ "application/x-www-form-urlencoded"
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    assert URI.decode_query(body) == params
  end

  defp authorization do
    %{
      "device_code" => "device-secret",
      "user_code" => "ABCD-EFGH",
      "verification_uri" => "https://github.com/login/device",
      "expires_in" => 900,
      "interval" => 5
    }
  end

  defp tokens do
    %{
      "access_token" => "access-secret",
      "refresh_token" => "refresh-secret",
      "token_type" => "bearer",
      "expires_in" => 28_800,
      "refresh_token_expires_in" => 15_897_600
    }
  end

  defp stub, do: {__MODULE__, System.unique_integer([:positive])}
  defp options(stub), do: [client_id: "fixture-client", plug: {Req.Test, stub}]
end
