defmodule Fornacast.LegacyTursoPreflight do
  @moduledoc false

  @acknowledgement_env "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA"
  @legacy_path_env "FORNACAST_LEGACY_TURSO_DATABASE_PATH"
  @default_legacy_path "/data/fornacast.db"
  @postgres_adapters ["postgres", "postgresql"]

  @doc """
  Refuses PostgreSQL startup when an unacknowledged legacy Turso database exists.
  """
  @spec verify!() :: :ok
  def verify! do
    if Application.get_env(:fornacast, :legacy_turso_preflight, false) and
         Application.get_env(:fornacast, :database_adapter) in @postgres_adapters do
      verify_legacy_path!()
    end

    :ok
  end

  @doc false
  @spec validate_path(term()) :: {:ok, String.t()} | {:error, :invalid_path}
  def validate_path(value) do
    with true <- is_binary(value),
         true <- byte_size(value) in 1..4096,
         true <- String.valid?(value),
         true <- String.printable?(value),
         false <- Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value),
         :nomatch <- :binary.match(value, <<0>>),
         :absolute <- Path.type(value) do
      {:ok, Path.expand(value)}
    else
      _invalid -> {:error, :invalid_path}
    end
  end

  defp verify_legacy_path! do
    path =
      @legacy_path_env
      |> System.get_env(@default_legacy_path)
      |> validated_path!()

    if File.exists?(path) and System.get_env(@acknowledgement_env) != "true" do
      raise "legacy Turso database detected at #{inspect(path)}; back it up and set " <>
              "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true only after an intentional transition"
    end

    :ok
  end

  defp validated_path!(value) do
    case validate_path(value) do
      {:ok, path} ->
        path

      {:error, :invalid_path} ->
        raise "FORNACAST_LEGACY_TURSO_DATABASE_PATH must be a printable absolute path"
    end
  end
end
