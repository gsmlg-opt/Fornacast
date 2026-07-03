defmodule GitTransport do
  @moduledoc """
  Git-over-SSH transport boundary.
  """

  def parse_exec(command), do: GitTransport.Command.parse(command)

  def handle_exec(username, command, peer \\ nil) do
    GitTransport.Exec.handle(username, command, peer)
  end

  def start_ssh_daemon(opts \\ []) do
    GitTransport.Daemon.start_link(opts)
  end

  def ssh_daemon_info(server \\ GitTransport.Daemon) do
    GitTransport.Daemon.info(server)
  end
end
