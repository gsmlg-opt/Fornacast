defmodule Fornacast.ConfigStore do
  @moduledoc """
  App-level key/value configuration backed by Concord's durable Turso engine.
  """

  @prefix "fornacast:config:"

  @type key :: atom() | String.t()

  @spec put(key(), term(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ []) do
    key
    |> storage_key()
    |> Concord.Turso.put(value, opts)
  end

  @spec fetch(key(), keyword()) :: {:ok, term()} | {:error, term()}
  def fetch(key, opts \\ []) do
    key
    |> storage_key()
    |> Concord.Turso.get(opts)
  end

  @spec get(key(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(key, default \\ nil, opts \\ []) do
    case fetch(key, opts) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> {:ok, default}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete(key(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    key
    |> storage_key()
    |> Concord.Turso.delete(opts)
  end

  defp storage_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> storage_key()
  end

  defp storage_key(@prefix <> _rest = key), do: key
  defp storage_key(key) when is_binary(key), do: @prefix <> key
end
