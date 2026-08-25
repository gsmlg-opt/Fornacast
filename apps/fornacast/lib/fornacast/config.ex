defmodule Fornacast.Config do
  @moduledoc """
  Runtime configuration accessors used by all Fornacast apps.
  """

  def base_url do
    :fornacast
    |> Application.fetch_env!(:base_url)
    |> String.trim_trailing("/")
  end

  def repo_storage_root do
    :fornacast
    |> Application.fetch_env!(:repo_storage_root)
    |> Path.expand()
  end

  def release_asset_storage_root do
    :fornacast
    |> Application.fetch_env!(:release_asset_storage_root)
    |> Path.expand()
  end

  def release_asset_max_bytes do
    Application.fetch_env!(:fornacast, :release_asset_max_bytes)
  end

  def release_asset_gc_grace_seconds do
    Application.fetch_env!(:fornacast, :release_asset_gc_grace_seconds)
  end

  @spec github_credential_keyring() ::
          {:ok, %{active: String.t(), keys: %{String.t() => binary()}}}
          | {:error, :credential_service_unavailable}
  def github_credential_keyring do
    case Application.get_env(:fornacast, :github_credential_keyring, :unavailable) do
      %{active: active, keys: keys} = keyring
      when is_binary(active) and byte_size(active) in 1..255 and is_map(keys) ->
        valid? =
          map_size(keys) > 0 and
            match?(
              {:ok, key} when is_binary(key) and byte_size(key) == 32,
              Map.fetch(keys, active)
            ) and
            Enum.all?(keys, fn
              {key_id, key}
              when is_binary(key_id) and byte_size(key_id) in 1..255 and is_binary(key) ->
                byte_size(key) == 32

              _ ->
                false
            end)

        if valid?,
          do: {:ok, keyring},
          else: {:error, :credential_service_unavailable}

      _ ->
        {:error, :credential_service_unavailable}
    end
  end

  def ssh_host do
    Application.fetch_env!(:fornacast, :ssh_host)
  end

  def ssh_bind_ip do
    Application.fetch_env!(:fornacast, :ssh_bind_ip)
  end

  def ssh_port do
    Application.fetch_env!(:fornacast, :ssh_port)
  end

  def ssh_system_dir do
    :fornacast
    |> Application.fetch_env!(:ssh_system_dir)
    |> Path.expand()
  end

  def ssh_enabled? do
    Application.fetch_env!(:fornacast, :ssh_enabled)
  end
end
