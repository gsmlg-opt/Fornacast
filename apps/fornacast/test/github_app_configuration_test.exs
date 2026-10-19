defmodule Fornacast.GitHubAppConfigurationTest do
  use ExUnit.Case, async: false

  @config_root Path.expand("../../../config", __DIR__)
  @keys ~w(FORNACAST_GITHUB_APP_ID FORNACAST_GITHUB_APP_SLUG FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE FORNACAST_GITHUB_WEBHOOK_SECRET FORNACAST_GITHUB_WEBHOOK_MAX_BYTES)

  setup do
    original = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "development and releases disable an unconfigured App" do
    for environment <- [:dev, :prod] do
      assert app_configuration(environment) == :disabled
    end
  end

  test "development and releases accept the same complete App configuration" do
    configure_app()

    for environment <- [:dev, :prod] do
      assert %{
               app_id: 123_456,
               app_slug: "fornacast-test",
               private_key_file: private_key_file,
               webhook_secret: secret,
               webhook_max_bytes: 1_048_576
             } = app_configuration(environment)

      assert private_key_file == Path.expand("/tmp/fornacast-app-test.pem")
      assert secret.() == "test-only-webhook-secret"
    end
  end

  test "partial App configuration fails explicitly in development and releases" do
    System.put_env("FORNACAST_GITHUB_APP_ID", "123456")

    for environment <- [:dev, :prod] do
      assert_raise RuntimeError, ~r/GitHub App configuration requires/, fn ->
        app_configuration(environment)
      end
    end
  end

  test "invalid App identity and webhook limits fail before starting workers" do
    configure_app()

    for {key, invalid, message} <- [
          {"FORNACAST_GITHUB_APP_ID", "-1", ~r/APP_ID/},
          {"FORNACAST_GITHUB_APP_SLUG", "not/a/slug", ~r/APP_SLUG/},
          {"FORNACAST_GITHUB_WEBHOOK_MAX_BYTES", "1048577", ~r/WEBHOOK_MAX_BYTES/}
        ] do
      configure_app()
      System.put_env(key, invalid)

      for environment <- [:dev, :prod] do
        assert_raise RuntimeError, message, fn -> app_configuration(environment) end
      end
    end
  end

  defp configure_app do
    System.put_env(%{
      "FORNACAST_GITHUB_APP_ID" => "123456",
      "FORNACAST_GITHUB_APP_SLUG" => "fornacast-test",
      "FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE" => "/tmp/fornacast-app-test.pem",
      "FORNACAST_GITHUB_WEBHOOK_SECRET" => "test-only-webhook-secret"
    })

    System.delete_env("FORNACAST_GITHUB_WEBHOOK_MAX_BYTES")
  end

  defp app_configuration(environment) do
    file = if environment == :dev, do: "dev.exs", else: "runtime.exs"
    options = [env: environment, target: :host]

    options =
      if environment == :prod, do: Keyword.put(options, :imports, :disabled), else: options

    @config_root
    |> Path.join(file)
    |> Config.Reader.read!(options)
    |> Keyword.fetch!(:forge_github)
    |> Keyword.fetch!(:app_configuration)
  end
end
