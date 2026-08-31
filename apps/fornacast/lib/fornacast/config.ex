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

  @spec repository_cleanup() :: %{
          grace_seconds: pos_integer(),
          interval_ms: pos_integer(),
          deadline_ms: pos_integer(),
          lease_seconds: pos_integer(),
          backoff_min_seconds: pos_integer(),
          backoff_max_seconds: pos_integer()
        }
  def repository_cleanup do
    grace = Application.fetch_env!(:forge_imports, :repository_cleanup_grace_seconds)
    interval = Application.fetch_env!(:forge_imports, :repository_cleanup_interval_ms)
    deadline = Application.fetch_env!(:forge_imports, :repository_cleanup_deadline_ms)
    lease = Application.fetch_env!(:forge_imports, :repository_cleanup_lease_seconds)
    backoff_min = Application.fetch_env!(:forge_imports, :repository_cleanup_backoff_min_seconds)
    backoff_max = Application.fetch_env!(:forge_imports, :repository_cleanup_backoff_max_seconds)
    limits = Module.concat([GitCore, Limits])
    minimum_grace = apply(limits, :minimum_repository_cleanup_grace_seconds, [])

    remote_total_ms =
      apply(limits, :get, [:remote_wall_time_ms]) +
        apply(limits, :get, [:remote_kill_escalation_ms]) +
        apply(limits, :get, [:remote_cleanup_wait_ms])

    valid? =
      is_integer(grace) and grace >= minimum_grace and grace * 1_000 > remote_total_ms and
        is_integer(interval) and interval in 1_000..300_000 and
        is_integer(deadline) and deadline in 1_000..300_000 and
        is_integer(lease) and lease > div(deadline + 999, 1_000) and lease <= 3_600 and
        is_integer(backoff_min) and is_integer(backoff_max) and
        30 <= backoff_min and backoff_min <= backoff_max and backoff_max <= 21_600

    if valid? do
      %{
        grace_seconds: grace,
        interval_ms: interval,
        deadline_ms: deadline,
        lease_seconds: lease,
        backoff_min_seconds: backoff_min,
        backoff_max_seconds: backoff_max
      }
    else
      raise ArgumentError, "invalid :forge_imports repository cleanup configuration"
    end
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
