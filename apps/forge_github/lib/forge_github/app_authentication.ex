defmodule ForgeGitHub.AppAuthentication do
  @moduledoc "GitHub App JWT and installation authentication APIs."

  alias ForgeGitHub.{
    AppConfig,
    AppInstallation,
    AppJWT,
    Client,
    Error,
    InstallationToken,
    InstallationTokenScope
  }

  @max_installation_pages 100

  @spec create_app_jwt(AppConfig.t(), keyword()) ::
          {:ok, AppJWT.t()} | {:error, :invalid_configuration | :invalid_clock}
  def create_app_jwt(config, opts \\ [])

  def create_app_jwt(%AppConfig{} = config, opts) when is_list(opts) do
    with {:ok, private_key} <- AppConfig.load_private_key(config),
         {:ok, now} <- current_time(opts) do
      issued_at = DateTime.add(now, -60)
      expires_at = DateTime.add(now, 540)
      header = encode_segment(%{"alg" => "RS256", "typ" => "JWT"})

      claims =
        encode_segment(%{
          "iat" => DateTime.to_unix(issued_at),
          "exp" => DateTime.to_unix(expires_at),
          "iss" => Integer.to_string(config.app_id)
        })

      signing_input = header <> "." <> claims
      signature = :public_key.sign(signing_input, :sha256, private_key)
      token = signing_input <> "." <> Base.url_encode64(signature, padding: false)

      {:ok,
       %AppJWT{
         token: token,
         issued_at: issued_at,
         expires_at: expires_at
       }}
    else
      {:error, :invalid_private_key} -> {:error, :invalid_configuration}
      {:error, :invalid_clock} = error -> error
    end
  rescue
    _exception -> {:error, :invalid_configuration}
  catch
    _kind, _reason -> {:error, :invalid_configuration}
  end

  def create_app_jwt(_config, _opts), do: {:error, :invalid_configuration}

  @spec list_installations(AppConfig.t(), keyword()) ::
          {:ok, [AppInstallation.t()]} | {:error, Error.t()}
  def list_installations(%AppConfig{} = config, opts \\ []) do
    with {:ok, jwt} <- create_app_jwt(config, opts),
         {:ok, installations} <- list_installation_pages(jwt, config, opts, 1, []) do
      {:ok, installations}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} when reason in [:invalid_configuration, :invalid_clock] ->
        {:error, Error.new(:invalid_request)}

      _invalid ->
        {:error, Error.new(:invalid_response)}
    end
  end

  @spec get_installation(AppConfig.t(), pos_integer(), keyword()) ::
          {:ok, AppInstallation.t()} | {:error, Error.t()}
  def get_installation(config, installation_id, opts \\ [])

  def get_installation(%AppConfig{} = config, installation_id, opts)
      when is_integer(installation_id) and installation_id in 1..9_223_372_036_854_775_807 do
    with {:ok, jwt} <- create_app_jwt(config, opts),
         {:ok, value} <-
           Client.request(
             jwt.token,
             :get,
             "/app/installations/#{installation_id}",
             app_opts(config, opts)
           ),
         {:ok, installation} <- AppInstallation.from_json(value) do
      {:ok, installation}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} when reason in [:invalid_configuration, :invalid_clock] ->
        {:error, Error.new(:invalid_request)}

      _invalid ->
        {:error, Error.new(:invalid_response)}
    end
  end

  def get_installation(_config, _installation_id, _opts),
    do: {:error, Error.new(:invalid_request)}

  @spec create_installation_token(AppConfig.t(), pos_integer(), map(), keyword()) ::
          {:ok, InstallationToken.t()} | {:error, Error.t()}
  def create_installation_token(config, installation_id, scope \\ %{}, opts \\ [])

  def create_installation_token(%AppConfig{} = config, installation_id, scope, opts)
      when is_integer(installation_id) and installation_id in 1..9_223_372_036_854_775_807 do
    with {:ok, canonical_scope, _cache_key} <- InstallationTokenScope.canonical(scope),
         {:ok, jwt} <- create_app_jwt(config, opts),
         {:ok, value} <-
           Client.request(
             jwt.token,
             :post,
             "/app/installations/#{installation_id}/access_tokens",
             installation_opts(installation_id, canonical_scope, opts)
           ),
         {:ok, token} <- InstallationToken.from_json(value) do
      {:ok, token}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :invalid_scope} ->
        {:error, Error.new(:invalid_request)}

      {:error, reason} when reason in [:invalid_configuration, :invalid_clock] ->
        {:error, Error.new(:invalid_request)}

      _invalid ->
        {:error, Error.new(:invalid_response)}
    end
  end

  def create_installation_token(_config, _installation_id, _scope, _opts),
    do: {:error, Error.new(:invalid_request)}

  defp normalize_installations(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, installations} ->
      case AppInstallation.from_json(value) do
        {:ok, installation} -> {:cont, {:ok, [installation | installations]}}
        {:error, :invalid_response} -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, installations} -> {:ok, Enum.reverse(installations)}
      error -> error
    end
  end

  defp list_installation_pages(jwt, config, opts, page, pages)
       when page <= @max_installation_pages do
    path = "/app/installations?per_page=100&page=#{page}"

    with {:ok, values} when is_list(values) and length(values) <= 100 <-
           Client.request(jwt.token, :get, path, app_opts(config, opts)),
         {:ok, installations} <- normalize_installations(values) do
      cond do
        length(values) < 100 ->
          {:ok, [installations | pages] |> Enum.reverse() |> List.flatten()}

        page == @max_installation_pages ->
          {:error, Error.new(:pagination_limit)}

        true ->
          list_installation_pages(jwt, config, opts, page + 1, [installations | pages])
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, Error.new(:invalid_response)}
    end
  end

  defp app_opts(config, opts), do: Keyword.put(opts, :gate_key, {:github_app, config.app_id})

  defp installation_opts(installation_id, scope, opts) do
    opts = Keyword.put(opts, :gate_key, {:github_installation, installation_id})

    if map_size(scope) == 0 do
      opts
    else
      json_scope = Map.new(scope, fn {key, value} -> {Atom.to_string(key), value} end)
      Keyword.put(opts, :json, json_scope)
    end
  end

  defp current_time(opts) do
    case Keyword.get(opts, :now, &DateTime.utc_now/0) do
      now when is_function(now, 0) ->
        case now.() do
          %DateTime{time_zone: "Etc/UTC"} = datetime ->
            {:ok, DateTime.truncate(datetime, :second)}

          _invalid ->
            {:error, :invalid_clock}
        end

      _invalid ->
        {:error, :invalid_clock}
    end
  rescue
    _exception -> {:error, :invalid_clock}
  catch
    _kind, _reason -> {:error, :invalid_clock}
  end

  defp encode_segment(value) do
    value |> JSON.encode!() |> Base.url_encode64(padding: false)
  end
end
