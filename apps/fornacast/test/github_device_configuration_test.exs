defmodule Fornacast.GitHubDeviceConfigurationTest do
  use ExUnit.Case, async: false

  @config_root Path.expand("../../../config", __DIR__)
  @variable "FORNACAST_GITHUB_DEVICE_CLIENT_ID"

  setup do
    original = System.get_env(@variable)
    System.delete_env(@variable)

    on_exit(fn ->
      if original, do: System.put_env(@variable, original), else: System.delete_env(@variable)
    end)
  end

  test "development and release runtime use the public Device Flow client independently" do
    for environment <- [:dev, :prod] do
      assert device_client(environment) == "Iv23lizCVE3E24s7fCA0"
    end
  end

  test "an operator override is read in development and release runtime" do
    System.put_env(@variable, "Iv23-test-self-hosted")

    for environment <- [:dev, :prod] do
      assert device_client(environment) == "Iv23-test-self-hosted"
    end
  end

  defp device_client(environment) do
    file = if environment == :dev, do: "config.exs", else: "runtime.exs"
    options = [env: environment, target: :host]

    options =
      if environment == :prod, do: Keyword.put(options, :imports, :disabled), else: options

    @config_root
    |> Path.join(file)
    |> Config.Reader.read!(options)
    |> Keyword.fetch!(:forge_github)
    |> Keyword.fetch!(:device_client_id)
  end
end
