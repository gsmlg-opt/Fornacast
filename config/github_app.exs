import Config

# Keep validation aligned with runtime.exs. Releases must inline this parser:
# their Config.Reader forbids import_config and ships only runtime.exs.
github_app_environment = %{
  app_id: System.get_env("FORNACAST_GITHUB_APP_ID"),
  app_slug: System.get_env("FORNACAST_GITHUB_APP_SLUG"),
  private_key_file: System.get_env("FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE"),
  webhook_secret: System.get_env("FORNACAST_GITHUB_WEBHOOK_SECRET")
}

configured_github_app_values =
  Enum.count(github_app_environment, fn {_key, value} -> is_binary(value) and value != "" end)

github_app_configuration =
  case configured_github_app_values do
    0 ->
      :disabled

    4 ->
      app_id =
        case Integer.parse(github_app_environment.app_id) do
          {value, ""} when value in 1..9_223_372_036_854_775_807 -> value
          _invalid -> raise "FORNACAST_GITHUB_APP_ID must be a positive decimal integer"
        end

      app_slug = github_app_environment.app_slug

      unless byte_size(app_slug) in 1..255 and
               Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, app_slug) do
        raise "FORNACAST_GITHUB_APP_SLUG is invalid"
      end

      private_key_file = github_app_environment.private_key_file

      unless byte_size(private_key_file) in 1..4_096 and
               private_key_file == String.trim(private_key_file) do
        raise "FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE is invalid"
      end

      webhook_max_bytes =
        case Integer.parse(System.get_env("FORNACAST_GITHUB_WEBHOOK_MAX_BYTES", "1048576")) do
          {value, ""} when value in 1..1_048_576 ->
            value

          _invalid ->
            raise "FORNACAST_GITHUB_WEBHOOK_MAX_BYTES must be between 1 and 1048576"
        end

      %{
        app_id: app_id,
        app_slug: app_slug,
        private_key_file: Path.expand(private_key_file),
        webhook_secret: fn -> System.fetch_env!("FORNACAST_GITHUB_WEBHOOK_SECRET") end,
        webhook_max_bytes: webhook_max_bytes
      }

    _partial ->
      raise "GitHub App configuration requires app ID, slug, private key file, and webhook secret"
  end

config :forge_github, :app_configuration, github_app_configuration
