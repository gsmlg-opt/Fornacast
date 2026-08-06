defmodule GitCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GitCore.ScanLimiter,
      Supervisor.child_spec(
        {Task.Supervisor, name: GitCore.MergeTaskSupervisor},
        id: GitCore.MergeTaskSupervisor,
        shutdown: :infinity
      ),
      GitCore.BlobLimiter,
      GitCore.Cache
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GitCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
