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
