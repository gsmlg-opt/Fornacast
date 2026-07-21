defmodule FornacastAPI.RateLimitTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias FornacastAPI.{ClientIP, MetaController, RateLimit, RequestBody, Response}

  @endpoint FornacastAPI.Endpoint
  @user_agent {"user-agent", "fornacast-rate-limit-test/1.0"}
  @rate_header_names [
    "x-ratelimit-limit",
    "x-ratelimit-remaining",
    "x-ratelimit-reset",
    "x-ratelimit-used",
    "x-ratelimit-resource"
  ]
  @rate_limit_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/rate-limits-for-the-rest-api"
  @contract_root Path.expand("../priv/openapi", __DIR__)

  defp put_req_header(conn, {name, value}), do: put_req_header(conn, name, value)

  test "anonymous and authenticated buckets use separate limits" do
    server =
      start_supervised!(
        {FornacastAPI.RateLimit, name: nil, anonymous_limit: 2, authenticated_limit: 3}
      )

    assert {:ok, %{limit: 2, used: 1, remaining: 1}} =
             RateLimit.consume({:ip, "192.0.2.10"}, 7_200, server: server)

    assert {:ok, %{limit: 3, used: 1, remaining: 2}} =
             RateLimit.consume({:token, 42}, 7_200, server: server)

    assert %{reset: 10_800} = RateLimit.peek({:token, 42}, 7_200, server: server)
  end

  test "an exhausted bucket remains capped until reset" do
    server = start_supervised!({RateLimit, name: nil, anonymous_limit: 1})

    assert {:ok, %{remaining: 0, used: 1}} =
             RateLimit.consume({:ip, "192.0.2.10"}, 10, server: server)

    assert {:error, %{remaining: 0, used: 1}} =
             RateLimit.consume({:ip, "192.0.2.10"}, 11, server: server)

    assert {:ok, %{remaining: 0, used: 1, reset: 7_200}} =
             RateLimit.consume({:ip, "192.0.2.10"}, 3_600, server: server)
  end

  test "advancing to a new window globally evicts stale identity buckets" do
    server = start_supervised!({RateLimit, name: nil})

    for identity <- 1..100 do
      assert {:ok, %{used: 1}} =
               RateLimit.consume({:ip, "192.0.2.#{identity}"}, 0, server: server)
    end

    table = :sys.get_state(server).table
    assert :ets.info(table, :size) == 100

    assert {:ok, %{used: 1, reset: 7_200}} =
             RateLimit.consume({:ip, "198.51.100.1"}, 3_600, server: server)

    assert :ets.info(table, :size) == 1
  end

  test "a delayed older timestamp does not evict the newer window" do
    server = start_supervised!({RateLimit, name: nil})
    identity = {:ip, "192.0.2.200"}

    assert {:ok, %{used: 1, reset: 7_200}} = RateLimit.consume(identity, 3_600, server: server)
    assert {:ok, %{used: 1, reset: 3_600}} = RateLimit.consume(identity, 0, server: server)
    assert {:ok, %{used: 2, reset: 7_200}} = RateLimit.consume(identity, 3_600, server: server)

    assert :sys.get_state(server).current_window == 3_600
  end

  test "configured limits cannot exceed production caps or be invalid" do
    for options <- [
          [anonymous_limit: 61],
          [authenticated_limit: 5_001],
          [anonymous_limit: -1],
          [authenticated_limit: "5000"],
          [window_seconds: 0],
          [window_seconds: -3_600],
          [window_seconds: "3600"],
          [window_seconds: 1],
          [window_seconds: 1_800],
          [window_seconds: 7_200]
        ] do
      assert_raise ArgumentError, fn -> RateLimit.init(options) end
    end
  end

  test "CIDR parsing canonicalizes networks and rejects invalid input" do
    ipv4 = ClientIP.parse_cidr!("10.255.2.3/8")
    ipv6 = ClientIP.parse_cidr!("2001:db8:1::9/32")

    assert ipv4.family == :ipv4
    assert ipv4.prefix == 8
    assert ClientIP.trusted?({10, 1, 2, 3}, [ipv4])
    refute ClientIP.trusted?({11, 1, 2, 3}, [ipv4])

    assert ipv6.family == :ipv6
    assert ipv6.prefix == 32
    assert ClientIP.trusted?({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}, [ipv6])
    refute ClientIP.trusted?({0x2001, 0x0DB9, 0, 0, 0, 0, 0, 1}, [ipv6])

    for value <- [
          "10.0.0.0",
          "10.0.0.0/33",
          "2001:db8::/129",
          "127.1/16",
          "010.0.0.1/8",
          "256.0.0.1/8",
          "+10.0.0.1/8",
          "10.0.0.1 /8",
          "10.0.0.0/+8",
          "10.0.0.0/-1",
          "10.0.0.0/ 8",
          "10.0.0.0/8x",
          "bad/8",
          nil
        ] do
      assert_raise ArgumentError, "invalid trusted proxy CIDR #{inspect(value)}", fn ->
        ClientIP.parse_cidr!(value)
      end
    end
  end

  test "application startup rejects malformed trusted proxy configuration before supervision" do
    previous = Application.fetch_env(:fornacast_api, :trusted_proxy_cidrs)
    Application.put_env(:fornacast_api, :trusted_proxy_cidrs, ["127.1/16"])

    try do
      assert_raise ArgumentError, "invalid trusted proxy CIDR \"127.1/16\"", fn ->
        FornacastAPI.Application.start(:normal, [])
      end
    after
      restore_env(:trusted_proxy_cidrs, previous)
    end
  end

  test "application startup caches parsed trusted proxy CIDRs and accepts them on restart" do
    previous = Application.fetch_env(:fornacast_api, :trusted_proxy_cidrs)

    Application.put_env(
      :fornacast_api,
      :trusted_proxy_cidrs,
      ["10.0.0.0/8", "2001:db8::/32"]
    )

    try do
      supervisor = Process.whereis(FornacastAPI.Supervisor)
      assert is_pid(supervisor)

      assert {:error, {:already_started, ^supervisor}} =
               FornacastAPI.Application.start(:normal, [])

      parsed = Application.fetch_env!(:fornacast_api, :trusted_proxy_cidrs)
      assert Enum.all?(parsed, &match?(%ClientIP.CIDR{}, &1))
      assert ClientIP.parse_cidrs!(parsed) == parsed

      assert {:error, {:already_started, ^supervisor}} =
               FornacastAPI.Application.start(:normal, [])

      assert Application.fetch_env!(:fornacast_api, :trusted_proxy_cidrs) == parsed
    after
      restore_env(:trusted_proxy_cidrs, previous)
    end

    assert_raise ArgumentError,
                 "trusted_proxy_cidrs must be a list, got: \"10.0.0.0/8\"",
                 fn -> ClientIP.parse_cidrs!("10.0.0.0/8") end
  end

  test "an untrusted immediate peer cannot spoof forwarding headers" do
    conn =
      client_conn(
        {203, 0, 113, 9},
        forwarded: "for=198.51.100.8",
        x_forwarded_for: "198.51.100.7"
      )

    assert ClientIP.effective(conn, [ClientIP.parse_cidr!("10.0.0.0/8")]) ==
             "203.0.113.9"
  end

  test "a trusted peer resolves the first untrusted X-Forwarded-For hop from the right" do
    conn =
      client_conn(
        {10, 0, 0, 2},
        x_forwarded_for: "198.51.100.1, 10.0.0.1"
      )

    assert ClientIP.effective(conn, [ClientIP.parse_cidr!("10.0.0.0/8")]) ==
             "198.51.100.1"
  end

  test "Forwarded supports mapped IPv6 proxies and bracketed IPv6 clients" do
    conn =
      client_conn(
        {0, 0, 0, 0, 0, 65_535, 2_560, 2},
        forwarded: ~s(for="[2001:db8::5]";proto=https)
      )

    trusted = [ClientIP.parse_cidr!("::ffff:10.0.0.0/104")]
    assert ClientIP.effective(conn, trusted) == "2001:db8::5"
  end

  test "valid Forwarded forms win over XFF and select the client from the right" do
    trusted = [ClientIP.parse_cidr!("10.0.0.0/8")]

    for {forwarded, expected} <- [
          {"for=198.51.100.20:443", "198.51.100.20"},
          {~s(for="198.51.100.21:8443"), "198.51.100.21"},
          {"for=[2001:db8::20]:443", "2001:db8::20"},
          {~s(for="[2001:db8::21]:8443"), "2001:db8::21"},
          {"For=198.51.100.22;proto=https, fOr=10.0.0.1", "198.51.100.22"},
          {"for=198.51.100.23;proto=\"https\tsecure\";by=\"proxy\\\"edge\"", "198.51.100.23"},
          {"for=10.0.0.5, for=10.0.0.6", "10.0.0.5"}
        ] do
      conn =
        client_conn(
          {10, 0, 0, 2},
          forwarded: forwarded,
          x_forwarded_for: "203.0.113.99"
        )

      assert ClientIP.effective(conn, trusted) == expected
    end
  end

  test "Forwarded handles obs-text bytes without assuming UTF-8" do
    trusted = [ClientIP.parse_cidr!("10.0.0.0/8")]

    valid_extension =
      raw_forwarded_conn(
        {10, 0, 0, 2},
        <<"for=198.51.100.24;ext=\"", 0xE9, "\"">>
      )

    valid_escaped_extension =
      raw_forwarded_conn(
        {10, 0, 0, 2},
        <<"for=198.51.100.24;ext=", ?", ?\\, 0xE9, ?">>
      )

    invalid_address =
      raw_forwarded_conn(
        {10, 0, 0, 2},
        <<"for=\"198.51.100.", 0xE9, "\"">>
      )

    invalid_name =
      raw_forwarded_conn(
        {10, 0, 0, 2},
        <<"for=198.51.100.24;e", 0xE9, "xt=value">>
      )

    unicode_whitespace =
      raw_forwarded_conn(
        {10, 0, 0, 2},
        <<0xC2, 0xA0, "for=198.51.100.24">>
      )

    invalid_xff =
      {10, 0, 0, 2}
      |> bare_conn()
      |> Map.update!(:req_headers, &[{"x-forwarded-for", <<"198.51.100.", 0xE9>>} | &1])

    assert ClientIP.effective(valid_extension, trusted) == "198.51.100.24"
    assert ClientIP.effective(valid_escaped_extension, trusted) == "198.51.100.24"
    assert ClientIP.effective(invalid_address, trusted) == "10.0.0.2"
    assert ClientIP.effective(invalid_name, trusted) == "10.0.0.2"
    assert ClientIP.effective(unicode_whitespace, trusted) == "10.0.0.2"
    assert ClientIP.effective(invalid_xff, trusted) == "10.0.0.2"
  end

  test "malformed or duplicate selected forwarding headers fail closed" do
    trusted = [ClientIP.parse_cidr!("10.0.0.0/8")]

    malformed =
      for headers <- [
            [forwarded: ~s(for="[2001:db8::5"), x_forwarded_for: "198.51.100.1"],
            [forwarded: "for=198.51.100.1;For=198.51.100.2"],
            [forwarded: "for=198.51.100.1;proto=https;proto=http"],
            [forwarded: "for=198.51.100.1;by=proxy;by=other"],
            [forwarded: "for=198.51.100.1;Proto=https;pRoTo=http"],
            [forwarded: "for=198.51.100.1;proto=not valid"],
            [forwarded: "for=198.51.100.1, proto=https"],
            [forwarded: "for=unknown"],
            [forwarded: "for=_obfuscated"],
            [forwarded: "for=198.51.100.1:+443"],
            [forwarded: "for=[2001:db8::1]:+443"],
            [forwarded: "for=198.51.100.1:-1"],
            [forwarded: "for=198.51.100.1:65536"],
            [forwarded: "for=198.51.100.1:443x"],
            [forwarded: "for=198.51.100.1: 443"],
            [forwarded: "for=127.1"],
            [forwarded: "for=010.0.0.1"],
            [forwarded: "for=256.0.0.1"],
            [forwarded: "for=+198.51.100.1"],
            [forwarded: ~s(for="198.51.100.1 ")],
            [x_forwarded_for: "198.51.100.1, not-an-address"],
            [x_forwarded_for: "127.1"],
            [x_forwarded_for: "010.0.0.1"],
            [x_forwarded_for: "256.0.0.1"],
            [x_forwarded_for: "+198.51.100.1"]
          ] do
        client_conn({10, 0, 0, 2}, headers)
      end

    quoted_controls =
      for control <- [0, 1, 10, 13, 31, 127], escaped <- [false, true] do
        prefix = if escaped, do: "bad\\", else: "bad"

        raw_forwarded_conn(
          {10, 0, 0, 2},
          "for=198.51.100.1;proto=\"" <> prefix <> <<control>> <> "value\""
        )
      end

    duplicate_header =
      {10, 0, 0, 2}
      |> client_conn()
      |> Map.update!(:req_headers, fn headers ->
        [{"forwarded", "for=198.51.100.1"}, {"forwarded", "for=198.51.100.2"} | headers]
      end)

    duplicate_xff =
      {10, 0, 0, 2}
      |> client_conn()
      |> Map.update!(:req_headers, fn headers ->
        [
          {"x-forwarded-for", "198.51.100.1"},
          {"x-forwarded-for", "198.51.100.2"}
          | headers
        ]
      end)

    for conn <- malformed ++ quoted_controls ++ [duplicate_header, duplicate_xff] do
      assert ClientIP.effective(conn, trusted) == "10.0.0.2"
    end
  end

  test "/versions consumes and /rate_limit peeks without consuming for both API versions" do
    remote_ip = {192, 0, 2, 20}

    first_peek = api_conn(remote_ip) |> get("/api/v3/rate_limit")
    first_headers = assert_rate_headers(first_peek, used: 0, remaining: 60, limit: 60)
    assert_rate_limit_body_matches_headers(first_peek, first_headers, "2022-11-28")

    assert_valid_rate_limit_response(first_peek, "2022-11-28")

    consumed = api_conn(remote_ip) |> get("/api/v3/versions")
    assert json_response(consumed, 200) == ["2022-11-28", "2026-03-10"]
    assert_rate_headers(consumed, used: 1, remaining: 59, limit: 60)

    second_peek =
      api_conn(remote_ip)
      |> put_req_header("x-github-api-version", "2026-03-10")
      |> get("/api/v3/rate_limit")

    second_headers = assert_rate_headers(second_peek, used: 1, remaining: 59, limit: 60)
    assert_rate_limit_body_matches_headers(second_peek, second_headers, "2026-03-10")

    assert_valid_rate_limit_response(second_peek, "2026-03-10")
  end

  test "rate limit responses render the bucket snapshot assigned by the plug" do
    bucket = %RateLimit.Bucket{
      limit: 42,
      remaining: 17,
      reset: 123_456,
      used: 25,
      resource: "assigned-core"
    }

    core = %{
      "limit" => 42,
      "remaining" => 17,
      "reset" => 123_456,
      "used" => 25
    }

    for {version, expected} <- [
          {"2022-11-28", %{"resources" => %{"core" => core}, "rate" => core}},
          {"2026-03-10", %{"resources" => %{"core" => core}}}
        ] do
      response =
        build_conn()
        |> assign(:api_version, version)
        |> assign(:rate_limit_identity, {:ip, "203.0.113.#{version}"})
        |> assign(:rate_limit_bucket, bucket)
        |> MetaController.rate_limit(%{})

      assert json_response(response, 200) == expected
      assert_exact_rate_limit_keys(JSON.decode!(response.resp_body), version)
    end
  end

  test "only GET /rate_limit peeks without consuming" do
    remote_ip = {192, 0, 2, 23}

    post_response =
      api_conn(remote_ip)
      |> put_req_header("content-type", "application/json")
      |> post("/api/v3/rate_limit", "{}")

    assert json_response(post_response, 404)["message"] == "Not Found"
    assert_rate_headers(post_response, used: 1, remaining: 59, limit: 60)

    get_response = api_conn(remote_ip) |> get("/api/v3/rate_limit")
    assert json_response(get_response, 200)["resources"]["core"]["used"] == 1
    assert_rate_headers(get_response, used: 1, remaining: 59, limit: 60)
  end

  test "authenticated buckets are keyed by API-key ID rather than client IP" do
    {first_secret, second_secret} = create_api_keys!()

    first =
      api_conn({192, 0, 2, 21})
      |> put_req_header("authorization", "Bearer #{first_secret}")
      |> get("/api/v3/versions")

    assert_rate_headers(first, used: 1, remaining: 4_999, limit: 5_000)

    same_key_different_ip =
      api_conn({192, 0, 2, 22})
      |> put_req_header("authorization", "token #{first_secret}")
      |> get("/api/v3/versions")

    assert_rate_headers(same_key_different_ip, used: 2, remaining: 4_998, limit: 5_000)

    different_key_same_ip =
      api_conn({192, 0, 2, 21})
      |> put_req_header("authorization", "Bearer #{second_secret}")
      |> get("/api/v3/versions")

    assert_rate_headers(different_key_same_ip, used: 1, remaining: 4_999, limit: 5_000)

    anonymous_same_ip = api_conn({192, 0, 2, 21}) |> get("/api/v3/versions")
    assert_rate_headers(anonymous_same_ip, used: 1, remaining: 59, limit: 60)
  end

  test "missing User-Agent is charged exactly once" do
    remote_ip = {192, 0, 2, 30}
    response = remote_ip |> bare_conn() |> get("/api/v3/versions")

    assert json_response(response, 403)["message"] == "User agent required"
    assert_charged_once(response, remote_ip)
  end

  test "an invalid API version is charged exactly once" do
    remote_ip = {192, 0, 2, 31}

    response =
      api_conn(remote_ip)
      |> put_req_header("x-github-api-version", "2099-01-01")
      |> get("/api/v3/versions")

    assert json_response(response, 400)["message"] == "Bad Request"
    assert_charged_once(response, remote_ip)
  end

  test "invalid authentication is charged anonymously exactly once" do
    remote_ip = {192, 0, 2, 32}

    response =
      api_conn(remote_ip)
      |> put_req_header("authorization", "Bearer fc_pat_invalid")
      |> get("/api/v3/versions")

    assert json_response(response, 401)["message"] == "Bad credentials"
    assert_charged_once(response, remote_ip)
  end

  test "a malformed JSON error after the rate plug is charged exactly once" do
    remote_ip = {192, 0, 2, 33}

    conn =
      Plug.Test.conn("POST", "/api/v3/example", ~s({"name":))
      |> Map.put(:remote_ip, remote_ip)
      |> put_req_header(@user_agent)
      |> put_req_header("content-type", "application/json")
      |> FornacastAPI.Plugs.RequestContext.call([])
      |> FornacastAPI.Plugs.RateLimit.call([])

    assert {:error, error, :malformed_json, conn} = RequestBody.read_json(conn, :ordinary, [])
    response = Response.error(conn, error)

    assert json_response(response, 400)["message"] == "Bad Request"
    assert_charged_once(response, remote_ip)
  end

  test "API and upload fallback errors are each charged exactly once" do
    for {path, remote_ip} <- [
          {"/api/v3/not-a-resource", {192, 0, 2, 34}},
          {"/api/uploads/not-a-resource", {192, 0, 2, 35}}
        ] do
      response = api_conn(remote_ip) |> get(path)

      assert json_response(response, 404)["message"] == "Not Found"
      assert_charged_once(response, remote_ip)
    end
  end

  test "spoofed X-Forwarded-For is ignored for untrusted peers" do
    remote_ip = {203, 0, 113, 40}

    first =
      api_conn(remote_ip)
      |> put_req_header("x-forwarded-for", "198.51.100.1")
      |> get("/api/v3/versions")

    assert_rate_headers(first, used: 1, remaining: 59, limit: 60)

    second =
      api_conn(remote_ip)
      |> put_req_header("x-forwarded-for", "198.51.100.2")
      |> get("/api/v3/versions")

    assert_rate_headers(second, used: 2, remaining: 58, limit: 60)

    different_peer =
      api_conn({203, 0, 113, 41})
      |> put_req_header("x-forwarded-for", "198.51.100.1")
      |> get("/api/v3/versions")

    assert_rate_headers(different_peer, used: 1, remaining: 59, limit: 60)
  end

  test "distinct clients behind a trusted proxy use distinct buckets" do
    previous = Application.get_env(:fornacast_api, :trusted_proxy_cidrs, [])

    Application.put_env(
      :fornacast_api,
      :trusted_proxy_cidrs,
      ClientIP.parse_cidrs!(["10.0.0.0/8"])
    )

    try do
      first = proxied_conn("198.51.100.10") |> get("/api/v3/versions")
      second = proxied_conn("198.51.100.11") |> get("/api/v3/versions")
      first_again = proxied_conn("198.51.100.10") |> get("/api/v3/versions")

      assert_rate_headers(first, used: 1, remaining: 59, limit: 60)
      assert_rate_headers(second, used: 1, remaining: 59, limit: 60)
      assert_rate_headers(first_again, used: 2, remaining: 58, limit: 60)
    after
      Application.put_env(:fornacast_api, :trusted_proxy_cidrs, previous)
    end
  end

  test "an exhausted endpoint bucket returns a stable 429 without growing usage" do
    remote_ip = {192, 0, 2, 60}

    last_allowed =
      Enum.reduce(1..60, nil, fn used, _previous ->
        response = api_conn(remote_ip) |> get("/api/v3/versions")
        assert response.status == 200
        assert_rate_headers(response, used: used, remaining: 60 - used, limit: 60)
        response
      end)

    exhausted = api_conn(remote_ip) |> get("/api/v3/versions")

    assert json_response(exhausted, 429) == %{
             "documentation_url" => @rate_limit_documentation_url,
             "message" => "API rate limit exceeded"
           }

    last_headers = assert_rate_headers(last_allowed, used: 60, remaining: 0, limit: 60)
    exhausted_headers = assert_rate_headers(exhausted, used: 60, remaining: 0, limit: 60)
    assert exhausted_headers["x-ratelimit-reset"] == last_headers["x-ratelimit-reset"]
  end

  test "an already exhausted early halt is replaced with a rate-limit error" do
    remote_ip = {192, 0, 2, 61}

    last_allowed =
      Enum.reduce(1..60, nil, fn _used, _previous ->
        response = api_conn(remote_ip) |> get("/api/v3/versions")
        assert response.status == 200
        response
      end)

    early_halt = remote_ip |> bare_conn() |> get("/api/v3/versions")

    assert json_response(early_halt, 429) == %{
             "documentation_url" => @rate_limit_documentation_url,
             "message" => "API rate limit exceeded"
           }

    last_headers = assert_rate_headers(last_allowed, used: 60, remaining: 0, limit: 60)
    early_headers = assert_rate_headers(early_halt, used: 60, remaining: 0, limit: 60)
    assert early_headers["x-ratelimit-reset"] == last_headers["x-ratelimit-reset"]
  end

  defp client_conn(remote_ip, headers \\ []) do
    Enum.reduce(headers, bare_conn(remote_ip), fn
      {:forwarded, value}, conn -> put_req_header(conn, "forwarded", value)
      {:x_forwarded_for, value}, conn -> put_req_header(conn, "x-forwarded-for", value)
    end)
  end

  defp bare_conn(remote_ip), do: %{build_conn() | remote_ip: remote_ip}

  defp raw_forwarded_conn(remote_ip, value) do
    remote_ip
    |> bare_conn()
    |> Map.update!(:req_headers, &[{"forwarded", value} | &1])
  end

  defp api_conn(remote_ip) do
    remote_ip
    |> bare_conn()
    |> put_req_header(@user_agent)
  end

  defp proxied_conn(client_ip) do
    {10, 0, 0, 2}
    |> api_conn()
    |> put_req_header("x-forwarded-for", client_ip)
  end

  defp assert_charged_once(response, remote_ip) do
    assert_rate_headers(response, used: 1, remaining: 59, limit: 60)

    next_response = api_conn(remote_ip) |> get("/api/v3/versions")
    assert_rate_headers(next_response, used: 2, remaining: 58, limit: 60)
  end

  defp assert_rate_headers(conn, expected) do
    headers =
      Map.new(@rate_header_names, fn name ->
        assert [value] = get_resp_header(conn, name)
        {name, value}
      end)

    for name <- @rate_header_names -- ["x-ratelimit-resource"] do
      assert {_value, ""} = Integer.parse(headers[name])
    end

    assert headers["x-ratelimit-resource"] == "core"
    assert headers["x-ratelimit-limit"] == Integer.to_string(expected[:limit])
    assert headers["x-ratelimit-remaining"] == Integer.to_string(expected[:remaining])
    assert headers["x-ratelimit-used"] == Integer.to_string(expected[:used])
    headers
  end

  defp core_from_headers(headers) do
    %{
      "limit" => String.to_integer(headers["x-ratelimit-limit"]),
      "remaining" => String.to_integer(headers["x-ratelimit-remaining"]),
      "reset" => String.to_integer(headers["x-ratelimit-reset"]),
      "used" => String.to_integer(headers["x-ratelimit-used"])
    }
  end

  defp assert_rate_limit_body_matches_headers(conn, headers, version) do
    core = core_from_headers(headers)

    expected =
      case version do
        "2022-11-28" -> %{"resources" => %{"core" => core}, "rate" => core}
        "2026-03-10" -> %{"resources" => %{"core" => core}}
      end

    assert json_response(conn, 200) == expected
  end

  defp assert_valid_rate_limit_response(conn, version) do
    document =
      @contract_root
      |> Path.join("ghes-3.21-#{version}.json")
      |> File.read!()
      |> JSON.decode!()
      |> OpenApiSpex.OpenApi.Decode.decode()

    schema =
      document.paths["/rate_limit"].get.responses["200"].content["application/json"].schema

    body = JSON.decode!(conn.resp_body)

    assert_exact_rate_limit_keys(body, version)
    assert {:ok, _cast} = OpenApiSpex.Cast.cast(schema, body)
  end

  defp assert_exact_rate_limit_keys(body, version) do
    expected_top_level_keys =
      case version do
        "2022-11-28" -> ["rate", "resources"]
        "2026-03-10" -> ["resources"]
      end

    assert Enum.sort(Map.keys(body)) == expected_top_level_keys
    assert Map.keys(body["resources"]) == ["core"]
    assert Enum.sort(Map.keys(body["resources"]["core"])) == ~w(limit remaining reset used)

    if version == "2022-11-28" do
      assert Enum.sort(Map.keys(body["rate"])) == ~w(limit remaining reset used)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:fornacast_api, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:fornacast_api, key)

  defp create_api_keys! do
    reset_database!()

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "rate-limit-user",
        email: "rate-limit@example.com",
        password: "correct horse battery staple"
      })

    {:ok, _first_key, first_secret} =
      ForgeAccounts.create_api_key(user, %{name: "first", scopes: ["repo"]})

    {:ok, _second_key, second_secret} =
      ForgeAccounts.create_api_key(user, %{name: "second", scopes: ["repo"]})

    {first_secret, second_secret}
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(["api_keys", "users"], fn table ->
          Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{table}", [])
        end)
    end
  end
end
