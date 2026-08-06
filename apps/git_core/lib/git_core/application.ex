defmodule GitCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @merge_shutdown 5_000

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: GitCore.Supervisor]
    Supervisor.start_link(child_specs(), opts)
  end

  @doc false
  def child_specs do
    [
      Supervisor.child_spec(
        {Task.Supervisor, name: GitCore.MergeTaskSupervisor},
        id: GitCore.MergeTaskSupervisor,
        shutdown: @merge_shutdown
      ),
      Supervisor.child_spec(GitCore.ScanLimiter, []),
      Supervisor.child_spec(GitCore.BlobLimiter, []),
      Supervisor.child_spec(GitCore.Cache, [])
    ]
  end
end
