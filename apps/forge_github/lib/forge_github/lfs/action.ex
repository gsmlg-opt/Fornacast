defmodule ForgeGitHub.LFS.Action do
  @moduledoc "An opaque, validated Git LFS Basic transfer action."

  @enforce_keys [:operation, :url, :headers]
  defstruct [:operation, :url, :headers, :expires_at]

  @type operation :: :download | :upload | :verify
  @opaque t :: %__MODULE__{
            operation: operation(),
            url: String.t(),
            headers: [{String.t(), String.t()}],
            expires_at: DateTime.t() | nil
          }

  @maximum_url_bytes 8_192
  @maximum_headers 100
  @maximum_header_bytes 65_536
  @blocked_headers ~w(connection content-length host keep-alive proxy-authenticate
                      proxy-authorization te trailer transfer-encoding upgrade)

  @doc false
  @spec new(operation(), String.t(), map(), DateTime.t() | nil) :: {:ok, t()} | :error
  def new(operation, url, headers, expires_at)
      when operation in [:download, :upload, :verify] and is_binary(url) and is_map(headers) and
             (is_nil(expires_at) or is_struct(expires_at, DateTime)) do
    with {:ok, normalized_url} <- validate_url(url),
         {:ok, normalized_headers} <- validate_headers(headers) do
      {:ok,
       %__MODULE__{
         operation: operation,
         url: normalized_url,
         headers: normalized_headers,
         expires_at: expires_at
       }}
    end
  end

  def new(_operation, _url, _headers, _expires_at), do: :error

  @doc false
  def new!(operation, url, headers, expires_at) do
    {:ok, action} = new(operation, url, headers, expires_at)
    action
  end

  @doc false
  @spec request(t()) :: {String.t(), [{String.t(), String.t()}]}
  def request(%__MODULE__{url: url, headers: headers}), do: {url, headers}

  @doc false
  def expired?(%__MODULE__{expires_at: nil}, _now, _skew_seconds), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, %DateTime{} = now, skew_seconds)
      when is_integer(skew_seconds) and skew_seconds >= 0 do
    now
    |> DateTime.add(skew_seconds)
    |> DateTime.compare(expires_at)
    |> Kernel.!==(:lt)
  end

  defp validate_url(url) when byte_size(url) in 1..@maximum_url_bytes do
    case URI.new(url) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: port,
         userinfo: nil,
         fragment: nil,
         path: "/" <> _rest
       } = uri}
      when is_binary(host) and port in [nil, 443] ->
        if safe_url_bytes?(url) and ForgeGitHub.LFS.EgressPolicy.valid_host?(host) do
          {:ok, URI.to_string(%{uri | scheme: "https", host: String.downcase(host), port: nil})}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp validate_url(_url), do: :error

  defp safe_url_bytes?(url) do
    String.valid?(url) and
      Enum.all?([<<0>>, "\r", "\n"], &(:binary.match(url, &1) == :nomatch))
  end

  defp validate_headers(headers) when map_size(headers) <= @maximum_headers do
    headers
    |> Enum.reduce_while({:ok, [], 0}, fn
      {name, value}, {:ok, acc, bytes} when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)
        next_bytes = bytes + byte_size(name) + byte_size(value)

        if valid_header?(name, value) and next_bytes <= @maximum_header_bytes,
          do: {:cont, {:ok, [{name, value} | acc], next_bytes}},
          else: {:halt, :error}

      _invalid, _state ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values, _bytes} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp validate_headers(_headers), do: :error

  defp valid_header?(name, value) do
    name != "" and name not in @blocked_headers and
      String.match?(name, ~r/\A[!#$%&'*+.^_`|~0-9a-z-]+\z/) and String.valid?(value) and
      Enum.all?([<<0>>, "\r", "\n"], &(:binary.match(value, &1) == :nomatch))
  end
end

defimpl Inspect, for: ForgeGitHub.LFS.Action do
  def inspect(_action, _options), do: "#ForgeGitHub.LFS.Action<redacted>"
end
