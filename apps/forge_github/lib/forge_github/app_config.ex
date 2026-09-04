defmodule ForgeGitHub.AppConfig do
  @moduledoc "Validated, redacted runtime configuration for a GitHub App."

  @max_signed_bigint 9_223_372_036_854_775_807
  @max_private_key_bytes 65_536
  @max_webhook_secret_bytes 4_096
  @max_webhook_bytes 1_048_576

  @enforce_keys [
    :app_id,
    :app_slug,
    :private_key_file,
    :webhook_secret,
    :webhook_max_bytes
  ]
  defstruct @enforce_keys

  @type secret_provider :: (-> String.t())
  @type t :: %__MODULE__{
          app_id: pos_integer(),
          app_slug: String.t(),
          private_key_file: String.t(),
          webhook_secret: secret_provider(),
          webhook_max_bytes: pos_integer()
        }

  @spec fetch() :: {:ok, t()} | {:error, :disabled | :invalid_configuration}
  def fetch do
    case Application.get_env(:forge_github, :app_configuration, :disabled) do
      :disabled -> {:error, :disabled}
      configuration -> {:ok, validate!(configuration)}
    end
  rescue
    ArgumentError -> {:error, :invalid_configuration}
  end

  @spec validate!(:disabled | t() | map()) :: :disabled | t()
  def validate!(:disabled), do: :disabled

  def validate!(configuration) when is_map(configuration) do
    configuration =
      case configuration do
        %__MODULE__{} = config -> Map.from_struct(config)
        map -> map
      end

    required = [
      :app_id,
      :app_slug,
      :private_key_file,
      :webhook_secret,
      :webhook_max_bytes
    ]

    unless Enum.all?(required, &Map.has_key?(configuration, &1)) do
      raise ArgumentError, "GitHub App configuration is incomplete"
    end

    app_id = Map.fetch!(configuration, :app_id)
    app_slug = Map.fetch!(configuration, :app_slug)
    private_key_file = Map.fetch!(configuration, :private_key_file)
    webhook_secret = Map.fetch!(configuration, :webhook_secret)
    webhook_max_bytes = Map.fetch!(configuration, :webhook_max_bytes)

    unless is_integer(app_id) and app_id in 1..@max_signed_bigint do
      raise ArgumentError, "GitHub App ID is invalid"
    end

    unless is_binary(app_slug) and byte_size(app_slug) in 1..255 and
             Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, app_slug) do
      raise ArgumentError, "GitHub App slug is invalid"
    end

    unless is_binary(private_key_file) and byte_size(private_key_file) in 1..4_096 and
             String.valid?(private_key_file) and private_key_file == String.trim(private_key_file) do
      raise ArgumentError, "GitHub App private key file is invalid"
    end

    expanded_private_key_file = Path.expand(private_key_file)

    unless is_function(webhook_secret, 0) do
      raise ArgumentError, "GitHub App webhook secret provider is invalid"
    end

    unless is_integer(webhook_max_bytes) and webhook_max_bytes in 1..@max_webhook_bytes do
      raise ArgumentError, "GitHub App webhook maximum is invalid"
    end

    config = %__MODULE__{
      app_id: app_id,
      app_slug: app_slug,
      private_key_file: expanded_private_key_file,
      webhook_secret: webhook_secret,
      webhook_max_bytes: webhook_max_bytes
    }

    case load_private_key(config) do
      {:ok, _private_key} -> :ok
      {:error, :invalid_private_key} -> raise ArgumentError, "GitHub App private key is invalid"
    end

    case read_webhook_secret(config) do
      {:ok, _secret} ->
        config

      {:error, :invalid_webhook_secret} ->
        raise ArgumentError, "GitHub App webhook secret is invalid"
    end
  end

  def validate!(_configuration), do: raise(ArgumentError, "GitHub App configuration is invalid")

  @doc false
  @spec load_private_key(t()) :: {:ok, tuple()} | {:error, :invalid_private_key}
  def load_private_key(%__MODULE__{private_key_file: path}) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size in 1..@max_private_key_bytes <-
           File.stat(path),
         {:ok, pem} when byte_size(pem) == size <- File.read(path),
         [entry] <- :public_key.pem_decode(pem),
         {:ok, key} <- decode_rsa_key(entry),
         true <- rsa_key?(key) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid_private_key}
    end
  rescue
    _exception -> {:error, :invalid_private_key}
  catch
    _kind, _reason -> {:error, :invalid_private_key}
  end

  @doc false
  @spec read_webhook_secret(t()) :: {:ok, String.t()} | {:error, :invalid_webhook_secret}
  def read_webhook_secret(%__MODULE__{webhook_secret: provider}) do
    case provider.() do
      secret
      when is_binary(secret) and byte_size(secret) in 1..@max_webhook_secret_bytes ->
        if String.valid?(secret) and :binary.match(secret, <<0>>) == :nomatch,
          do: {:ok, secret},
          else: {:error, :invalid_webhook_secret}

      _invalid ->
        {:error, :invalid_webhook_secret}
    end
  rescue
    _exception -> {:error, :invalid_webhook_secret}
  catch
    _kind, _reason -> {:error, :invalid_webhook_secret}
  end

  defp decode_rsa_key({kind, _der, encryption} = entry)
       when kind in [:RSAPrivateKey, :PrivateKeyInfo] and encryption == :not_encrypted do
    {:ok, :public_key.pem_entry_decode(entry)}
  rescue
    _exception -> {:error, :invalid_private_key}
  catch
    _kind, _reason -> {:error, :invalid_private_key}
  end

  defp decode_rsa_key(_entry), do: {:error, :invalid_private_key}

  defp rsa_key?(key) do
    is_tuple(key) and tuple_size(key) >= 4 and elem(key, 0) == :RSAPrivateKey and
      key |> elem(2) |> integer_bit_size() >= 2_048
  end

  defp integer_bit_size(integer) when is_integer(integer) and integer > 0 do
    integer |> :binary.encode_unsigned() |> bit_size()
  end

  defp integer_bit_size(_integer), do: 0
end

defimpl Inspect, for: ForgeGitHub.AppConfig do
  import Inspect.Algebra

  def inspect(config, opts) do
    concat([
      "#ForgeGitHub.AppConfig<",
      to_doc(
        [
          app_id: config.app_id,
          app_slug: config.app_slug,
          private_key_file: "[REDACTED]",
          webhook_secret: "[REDACTED]",
          webhook_max_bytes: config.webhook_max_bytes
        ],
        opts
      ),
      ">"
    ])
  end
end
