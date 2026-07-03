defmodule GitTransport.Exec do
  @moduledoc """
  Restricted SSH exec dispatcher for Git commands.
  """

  require Logger

  @unsupported_command "ERROR: Fornacast only supports Git commands over SSH.\n"
  @not_found "ERROR: Repository not found.\n"
  @unauthorized "ERROR: You do not have access to this repository.\n"

  def run(command, username, peer) do
    case handle_stream(to_string(username), to_string(command), peer) do
      :ok -> {:ok, ""}
      {:error, message} -> {:error, message}
    end
  end

  def handle(username, command, peer \\ nil)

  def handle(username, command, peer)
      when is_binary(username) and is_binary(command) do
    result =
      with {:ok, actor, parsed_command, repository} <- prepare(username, command) do
        dispatch(actor, parsed_command, repository, peer)
      end

    normalize_result(result)
  end

  def handle(_username, _command, _peer), do: {:error, @unsupported_command}

  def handle_stream(username, command, peer \\ nil)

  def handle_stream(username, command, peer)
      when is_binary(username) and is_binary(command) do
    result =
      with {:ok, actor, parsed_command, repository} <- prepare(username, command) do
        stream_dispatch(actor, parsed_command, repository, peer)
      end

    normalize_result(result)
  end

  def handle_stream(_username, _command, _peer), do: {:error, @unsupported_command}

  def prepare(username, command) when is_binary(username) and is_binary(command) do
    with {:ok, actor} <- fetch_actor(username),
         {:ok, parsed_command} <- GitTransport.parse_exec(command),
         {:ok, repository} <- ForgeRepos.resolve_git_path(parsed_command.path),
         :ok <- authorize(actor, parsed_command, repository) do
      {:ok, actor, parsed_command, repository}
    end
  end

  def error_message(:inactive_user) do
    Logger.info("SSH exec rejected for inactive or unknown user")
    @unauthorized
  end

  def error_message(:unsupported_command) do
    Logger.info("SSH exec rejected for unsupported command")
    @unsupported_command
  end

  def error_message(:invalid_command) do
    Logger.info("SSH exec rejected for invalid command")
    @unsupported_command
  end

  def error_message(:missing_path) do
    Logger.info("SSH exec rejected for missing repository path")
    @not_found
  end

  def error_message(:invalid_path) do
    Logger.info("SSH exec rejected for invalid repository path")
    @not_found
  end

  def error_message(:not_found) do
    Logger.info("SSH exec rejected for missing repository")
    @not_found
  end

  def error_message(:unauthorized) do
    Logger.info("SSH exec rejected by repository authorization")
    @unauthorized
  end

  def error_message(:not_implemented) do
    "ERROR: Git transport protocol is not implemented yet.\n"
  end

  def error_message(reason) when is_binary(reason), do: reason

  defp normalize_result(result) do
    case result do
      :ok ->
        :ok

      {:ok, _message} = ok ->
        ok

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  defp fetch_actor(username) do
    case ForgeAccounts.get_user_by_username(username) do
      %ForgeAccounts.User{state: :active} = user -> {:ok, user}
      _ -> {:error, :inactive_user}
    end
  end

  defp authorize(actor, %{operation: :upload_pack}, repository) do
    Fornacast.Access.authorize(actor, :repository_read, repository)
  end

  defp authorize(actor, %{operation: :receive_pack}, repository) do
    Fornacast.Access.authorize(actor, :repository_write, repository)
  end

  defp dispatch(actor, %{operation: :upload_pack}, repository, peer) do
    upload_pack(actor, repository, peer)
  end

  defp dispatch(actor, %{operation: :receive_pack}, repository, peer) do
    receive_pack(actor, repository, peer)
  end

  defp stream_dispatch(actor, %{operation: :upload_pack}, repository, peer) do
    upload_pack_stream(actor, repository, peer)
  end

  defp stream_dispatch(actor, %{operation: :receive_pack}, repository, peer) do
    receive_pack(actor, repository, peer)
  end

  def upload_pack(_actor, repository, _peer \\ nil) do
    GitTransport.UploadPack.advertise_refs(repository)
  end

  def upload_pack_stream(_actor, repository, _peer \\ nil) do
    GitTransport.UploadPack.serve(repository)
  end

  def receive_pack(_actor, repository, _peer \\ nil) do
    GitTransport.ReceivePack.advertise_refs(repository)
  end
end
