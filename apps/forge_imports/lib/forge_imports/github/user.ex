defmodule ForgeImports.GitHub.User do
  @moduledoc "A bounded GitHub user representation."

  @derive {Inspect, only: [:id, :login, :name, :avatar_url, :html_url]}
  @enforce_keys [:id, :login]
  defstruct [:id, :login, :name, :avatar_url, :html_url]

  @type t :: %__MODULE__{
          id: pos_integer(),
          login: String.t(),
          name: String.t() | nil,
          avatar_url: String.t() | nil,
          html_url: String.t() | nil
        }

  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_response}
  def from_json(%{} = value) do
    with {:ok, id} <- id(value["id"]),
         {:ok, login} <- string(value["login"], 255, required?: true),
         {:ok, name} <- string(value["name"], 255),
         {:ok, avatar_url} <- url(value["avatar_url"], ["avatars.githubusercontent.com"]),
         {:ok, html_url} <- url(value["html_url"], ["github.com"]) do
      {:ok,
       %__MODULE__{
         id: id,
         login: login,
         name: name,
         avatar_url: avatar_url,
         html_url: html_url
       }}
    else
      _error -> {:error, :invalid_response}
    end
  end

  def from_json(_value), do: {:error, :invalid_response}

  @doc false
  def id(value) when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807,
    do: {:ok, value}

  def id(_value), do: :error

  @doc false
  def string(value, max, opts \\ [])

  def string(nil, _max, opts) do
    if Keyword.get(opts, :required?, false), do: :error, else: {:ok, nil}
  end

  def string(value, max, opts) when is_binary(value) and is_integer(max) and max > 0 do
    required? = Keyword.get(opts, :required?, false)

    if String.valid?(value) and byte_size(value) <= max and
         :binary.match(value, <<0>>) == :nomatch and
         (not required? or String.trim(value) != "") do
      {:ok, value}
    else
      :error
    end
  end

  def string(_value, _max, _opts), do: :error

  @doc false
  def boolean(value) when is_boolean(value), do: {:ok, value}
  def boolean(_value), do: :error

  @doc false
  def url(nil, _hosts), do: {:ok, nil}

  def url(value, hosts) when is_binary(value) do
    with {:ok, value} <- string(value, 2_048),
         {:ok, uri} <- URI.new(value),
         "https" <- String.downcase(uri.scheme || ""),
         true <- String.downcase(uri.host || "") in hosts,
         nil <- uri.userinfo,
         true <- uri.port in [nil, 443] do
      {:ok, value}
    else
      _error -> :error
    end
  end

  def url(_value, _hosts), do: :error

  @doc false
  def datetime(nil), do: {:ok, nil}

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _error -> :error
    end
  end

  def datetime(_value), do: :error
end
