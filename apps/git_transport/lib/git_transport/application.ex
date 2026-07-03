defmodule GitTransport.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Fornacast.Config.ssh_enabled?() do
        [GitTransport.Daemon]
      else
        []
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GitTransport.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
