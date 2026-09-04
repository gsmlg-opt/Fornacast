defmodule ForgeGitHub.RuntimeConfigurationTest do
  use ExUnit.Case, async: false

  alias ForgeGitHub.AppConfig

  @environment ~w(
    FORNACAST_GITHUB_APP_ID
    FORNACAST_GITHUB_APP_SLUG
    FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE
    FORNACAST_GITHUB_WEBHOOK_SECRET
    FORNACAST_GITHUB_WEBHOOK_MAX_BYTES
    FORNACAST_GITHUB_WEBHOOK_MAX_CONCURRENCY
    FORNACAST_GITHUB_WEBHOOK_MAX_CONCURRENCY_PER_INSTALLATION
    FORNACAST_GITHUB_WEBHOOK_MAX_INTERNAL_ATTEMPTS
    FORNACAST_GITHUB_WEBHOOK_PROCESSOR_TIMEOUT_MS
    FORNACAST_GITHUB_WEBHOOK_BODY_TIMEOUT_MS
  )
  @runtime_config Path.expand("../../../../config/runtime.exs", __DIR__)

  setup do
    previous = Map.new(@environment, &{&1, System.get_env(&1)})

    previous_application_config =
      Application.get_env(:forge_github, :app_configuration, :disabled)

    Enum.each(@environment, &System.delete_env/1)

    on_exit(fn ->
      Application.put_env(:forge_github, :app_configuration, previous_application_config)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "application startup validates the mounted RSA key before starting workers" do
    Application.put_env(:forge_github, :app_configuration, %{
      app_id: 123_456,
      app_slug: "fornacast-sync",
      private_key_file: "/does/not/exist/fornacast-github-app.pem",
      webhook_secret: fn -> "runtime-webhook-secret" end,
      webhook_max_bytes: 65_536
    })

    assert_raise ArgumentError, ~r/private key/, fn ->
      ForgeGitHub.Application.start(:normal, [])
    end
  end

  test "runtime configuration is disabled when all GitHub App secrets are absent" do
    config = Config.Reader.read!(@runtime_config, env: :prod, target: :host)
    assert get_in(config, [:forge_github, :app_configuration]) == :disabled
    assert get_in(config, [:forge_mirrors, :webhook_worker_max_concurrency]) == 8

    assert get_in(config, [:forge_mirrors, :webhook_worker_max_concurrency_per_installation]) ==
             1

    assert get_in(config, [:forge_mirrors, :webhook_worker_max_internal_attempts]) == 10
    assert get_in(config, [:forge_mirrors, :webhook_worker_processor_timeout_ms]) == 25_000
    assert get_in(config, [:fornacast_api, :github_webhook_body_total_timeout_ms]) == 5_000
  end

  test "runtime configuration requires all identity and secret inputs and defaults the byte bound" do
    System.put_env("FORNACAST_GITHUB_APP_ID", "123456")

    assert_raise RuntimeError,
                 ~r/requires app ID, slug, private key file, and webhook secret/,
                 fn ->
                   Config.Reader.read!(@runtime_config, env: :prod, target: :host)
                 end

    private_key_file = write_private_key!()
    on_exit(fn -> File.rm(private_key_file) end)

    System.put_env(%{
      "FORNACAST_GITHUB_APP_SLUG" => "fornacast-sync",
      "FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE" => private_key_file,
      "FORNACAST_GITHUB_WEBHOOK_SECRET" => "runtime-webhook-secret"
    })

    config = Config.Reader.read!(@runtime_config, env: :prod, target: :host)
    raw = get_in(config, [:forge_github, :app_configuration])
    validated = AppConfig.validate!(raw)

    assert validated.app_id == 123_456
    assert validated.app_slug == "fornacast-sync"
    assert validated.private_key_file == Path.expand(private_key_file)
    assert validated.webhook_max_bytes == 1_048_576
    assert {:ok, "runtime-webhook-secret"} = AppConfig.read_webhook_secret(validated)
    refute inspect(validated) =~ "runtime-webhook-secret"
    assert :binary.match(:erlang.term_to_binary(config), "runtime-webhook-secret") == :nomatch
  end

  test "runtime configuration rejects an invalid webhook bound without exposing the secret" do
    private_key_file = write_private_key!()
    on_exit(fn -> File.rm(private_key_file) end)

    System.put_env(%{
      "FORNACAST_GITHUB_APP_ID" => "123456",
      "FORNACAST_GITHUB_APP_SLUG" => "fornacast-sync",
      "FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE" => private_key_file,
      "FORNACAST_GITHUB_WEBHOOK_SECRET" => "must-not-appear",
      "FORNACAST_GITHUB_WEBHOOK_MAX_BYTES" => "1048577"
    })

    exception =
      assert_raise RuntimeError, fn ->
        Config.Reader.read!(@runtime_config, env: :prod, target: :host)
      end

    message = Exception.message(exception)

    assert message =~ "FORNACAST_GITHUB_WEBHOOK_MAX_BYTES"
    refute message =~ "must-not-appear"
  end

  test "runtime configuration validates webhook worker and body bounds" do
    for {name, value} <- [
          {"FORNACAST_GITHUB_WEBHOOK_MAX_CONCURRENCY", "65"},
          {"FORNACAST_GITHUB_WEBHOOK_MAX_CONCURRENCY_PER_INSTALLATION", "65"},
          {"FORNACAST_GITHUB_WEBHOOK_MAX_INTERNAL_ATTEMPTS", "0"},
          {"FORNACAST_GITHUB_WEBHOOK_PROCESSOR_TIMEOUT_MS", "25001"},
          {"FORNACAST_GITHUB_WEBHOOK_BODY_TIMEOUT_MS", "0"}
        ] do
      System.put_env(name, value)

      assert_raise RuntimeError, ~r/#{name}/, fn ->
        Config.Reader.read!(@runtime_config, env: :prod, target: :host)
      end

      System.delete_env(name)
    end

    System.put_env("FORNACAST_GITHUB_WEBHOOK_MAX_CONCURRENCY", "2")
    System.put_env("FORNACAST_GITHUB_WEBHOOK_MAX_CONCURRENCY_PER_INSTALLATION", "3")

    assert_raise RuntimeError,
                 ~r/FORNACAST_GITHUB_WEBHOOK_MAX_CONCURRENCY_PER_INSTALLATION/,
                 fn ->
                   Config.Reader.read!(@runtime_config, env: :prod, target: :host)
                 end
  end

  defp write_private_key! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fornacast-runtime-key-#{System.unique_integer([:positive])}.pem"
      )

    private_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    File.write!(path, pem, [:binary, :exclusive])
    path
  end
end
