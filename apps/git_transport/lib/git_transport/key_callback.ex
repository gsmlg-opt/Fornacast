defmodule GitTransport.KeyCallback do
  @moduledoc """
  Erlang/OTP SSH key callback backed by Fornacast accounts.
  """

  @behaviour :ssh_server_key_api

  require Logger

  @impl :ssh_server_key_api
  def host_key(algorithm, daemon_options) do
    :ssh_file.host_key(algorithm, daemon_options)
  end

  @impl :ssh_server_key_api
  def is_auth_key(public_key, username, _daemon_options) do
    username = to_string(username)

    case ForgeAccounts.authenticate_ssh_key(username, public_key) do
      {:ok, user} ->
        Logger.metadata(user_id: user.id)
        true

      {:error, :unauthorized} ->
        Logger.info("SSH public key rejected")
        false
    end
  rescue
    error ->
      Logger.warning("SSH public key authentication failed: #{Exception.message(error)}")
      false
  end
end
