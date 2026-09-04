defmodule ForgeGitHub.AppAuthenticationTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{AppAuthentication, AppConfig, AppInstallation, AppJWT, InstallationToken}

  setup {Req.Test, :verify_on_exit!}

  setup context do
    path =
      Path.join(
        System.tmp_dir!(),
        "fornacast-github-app-#{System.unique_integer([:positive])}.pem"
      )

    private_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    File.write!(path, pem, [:binary, :exclusive])
    on_exit(fn -> File.rm(path) end)

    config =
      AppConfig.validate!(%{
        app_id: 123_456,
        app_slug: "fornacast-sync",
        private_key_file: path,
        webhook_secret: fn -> "webhook-secret-value" end,
        webhook_max_bytes: 65_536
      })

    {:ok, config: config, private_key: private_key, test: context.test}
  end

  test "configuration supports disabled mode and redacts secret-bearing fields", %{config: config} do
    assert :disabled = AppConfig.validate!(:disabled)
    rendered = inspect(config)
    assert rendered =~ "app_id: 123456"
    assert rendered =~ "private_key_file: \"[REDACTED]\""
    assert rendered =~ "webhook_secret: \"[REDACTED]\""
    refute rendered =~ config.private_key_file
    refute rendered =~ "webhook-secret-value"
  end

  test "configuration accepts an unencrypted PKCS#8 RSA key", %{
    config: config,
    private_key: private_key
  } do
    path = config.private_key_file <> ".pkcs8"

    pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:PrivateKeyInfo, private_key)
      ])

    File.write!(path, pem, [:binary, :exclusive])
    on_exit(fn -> File.rm(path) end)

    assert %AppConfig{private_key_file: ^path} =
             AppConfig.validate!(%{config | private_key_file: path})
  end

  test "configuration rejects partial, malformed, unreadable, non-RSA, and oversized material", %{
    config: config
  } do
    assert_raise ArgumentError, ~r/App configuration/, fn ->
      AppConfig.validate!(Map.delete(Map.from_struct(config), :app_slug))
    end

    assert_raise ArgumentError, ~r/App ID/, fn ->
      AppConfig.validate!(%{config | app_id: 0})
    end

    assert_raise ArgumentError, ~r/App slug/, fn ->
      AppConfig.validate!(%{config | app_slug: "Upper_Case"})
    end

    assert_raise ArgumentError, ~r/private key/, fn ->
      AppConfig.validate!(%{config | private_key_file: config.private_key_file <> ".missing"})
    end

    non_rsa_path = config.private_key_file <> ".non-rsa"
    File.write!(non_rsa_path, "not a private key", [:binary, :exclusive])
    on_exit(fn -> File.rm(non_rsa_path) end)

    assert_raise ArgumentError, ~r/private key/, fn ->
      AppConfig.validate!(%{config | private_key_file: non_rsa_path})
    end

    oversized_path = config.private_key_file <> ".oversized"
    File.write!(oversized_path, :binary.copy("x", 65_537), [:binary, :exclusive])
    on_exit(fn -> File.rm(oversized_path) end)

    assert_raise ArgumentError, ~r/private key/, fn ->
      AppConfig.validate!(%{config | private_key_file: oversized_path})
    end

    assert_raise ArgumentError, ~r/webhook maximum/, fn ->
      AppConfig.validate!(%{config | webhook_max_bytes: 1_048_577})
    end
  end

  test "JWT uses RS256 with the required backdated and short-lived claims", %{
    config: config,
    private_key: private_key
  } do
    now = ~U[2026-09-04 10:00:00Z]
    assert {:ok, %AppJWT{} = jwt} = AppAuthentication.create_app_jwt(config, now: fn -> now end)

    [encoded_header, encoded_claims, encoded_signature] = String.split(jwt.token, ".")
    header = encoded_header |> Base.url_decode64!(padding: false) |> JSON.decode!()
    claims = encoded_claims |> Base.url_decode64!(padding: false) |> JSON.decode!()
    signature = Base.url_decode64!(encoded_signature, padding: false)

    assert header == %{"alg" => "RS256", "typ" => "JWT"}

    assert claims == %{
             "exp" => DateTime.to_unix(now) + 540,
             "iat" => DateTime.to_unix(now) - 60,
             "iss" => "123456"
           }

    assert :public_key.verify(
             encoded_header <> "." <> encoded_claims,
             :sha256,
             signature,
             private_key
           )

    assert jwt.issued_at == DateTime.add(now, -60)
    assert jwt.expires_at == DateTime.add(now, 540)
    assert inspect(jwt) =~ "token: \"[REDACTED]\""
    refute inspect(jwt) =~ jwt.token
  end

  test "installation APIs use explicit app and installation gates and normalize responses", %{
    config: config
  } do
    stub = {__MODULE__, System.unique_integer([:positive])}
    parent = self()
    expires_at = ~U[2026-09-04 11:00:00Z]

    Req.Test.expect(stub, 3, fn conn ->
      assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
      assert length(String.split(jwt, ".")) == 3
      send(parent, {:request, conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/app/installations"} ->
          Req.Test.json(conn, [installation_json()])

        {"GET", "/app/installations/44"} ->
          Req.Test.json(conn, installation_json(%{"repository_selection" => "selected"}))

        {"POST", "/app/installations/44/access_tokens"} ->
          assert {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert JSON.decode!(body) == %{
                   "permissions" => %{"contents" => "write"},
                   "repository_ids" => [10, 11]
                 }

          Req.Test.json(conn, %{
            "token" => String.duplicate("t", 4_096),
            "expires_at" => DateTime.to_iso8601(expires_at),
            "permissions" => %{"contents" => "write"}
          })
      end
    end)

    opts = client_opts(stub, ~U[2026-09-04 10:00:00Z])

    assert {:ok, [%AppInstallation{id: 44, account_type: :organization, state: :active}]} =
             AppAuthentication.list_installations(config, opts)

    assert {:ok, %AppInstallation{repository_selection: :selected}} =
             AppAuthentication.get_installation(config, 44, opts)

    assert {:ok, %InstallationToken{} = token} =
             AppAuthentication.create_installation_token(
               config,
               44,
               %{permissions: %{"contents" => "write"}, repository_ids: [11, 10, 11]},
               opts
             )

    assert byte_size(token.token) == 4_096
    assert token.expires_at == expires_at
    assert token.permissions == %{"contents" => "write"}
    assert inspect(token) =~ "token: \"[REDACTED]\""
    refute inspect(token) =~ token.token
    assert_received {:request, "GET", "/app/installations"}
    assert_received {:request, "GET", "/app/installations/44"}
    assert_received {:request, "POST", "/app/installations/44/access_tokens"}
  end

  test "normalizers reject malformed installation identities and token metadata" do
    assert {:error, :invalid_response} =
             AppInstallation.from_json(installation_json(%{"account" => %{"id" => 1}}))

    assert {:error, :invalid_response} =
             InstallationToken.from_json(%{
               "token" => "short",
               "expires_at" => "not-a-time",
               "permissions" => %{}
             })
  end

  test "installation normalization accepts enterprise slugs without a login" do
    json =
      installation_json(%{
        "account" => %{"id" => 1_001, "slug" => "octo-enterprise", "type" => "Enterprise"}
      })

    assert {:ok,
            %AppInstallation{
              account_id: 1_001,
              account_login: "octo-enterprise",
              account_type: :enterprise
            }} = AppInstallation.from_json(json)
  end

  defp client_opts(stub, now) do
    [
      plug: {Req.Test, stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
      now: fn -> now end
    ]
  end

  defp installation_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 44,
        "account" => %{"id" => 99, "login" => "octo-org", "type" => "Organization"},
        "repository_selection" => "all",
        "permissions" => %{"contents" => "write", "metadata" => "read"},
        "suspended_at" => nil
      },
      overrides
    )
  end
end
