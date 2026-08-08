defmodule GitTransport.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @receive_pack_shutdown :infinity

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: GitTransport.Supervisor]
    Supervisor.start_link(child_specs(), opts)
  end

  @doc false
  def child_specs do
    daemon_children =
      if Fornacast.Config.ssh_enabled?() do
        [GitTransport.Daemon]
      else
        []
      end

    # The worker supervisor starts before its admission manager and the SSH
    # daemon. Reverse shutdown closes SSH first, then the manager atomically
    # stops admission and waits for every worker before the worker supervisor is
    # signalled. Waiting indefinitely is intentional: legacy native receive-pack
    # cannot be cancelled safely, and teardown must not release a writer lease
    # while its dirty NIF is still mutating.
    [
      Supervisor.child_spec(
        {Task.Supervisor, name: GitTransport.ReceivePackWorkerSupervisor},
        id: GitTransport.ReceivePackWorkerSupervisor,
        shutdown: @receive_pack_shutdown
      ),
      Supervisor.child_spec(
        {GitTransport.ReceivePackWorkerManager, name: GitTransport.ReceivePackWorkerManager},
        id: GitTransport.ReceivePackWorkerManager,
        shutdown: @receive_pack_shutdown
      )
    ] ++ daemon_children
  end
end
