defmodule FornacastAPI.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [FornacastAPI.Endpoint],
      strategy: :one_for_one,
      name: FornacastAPI.Supervisor
    )
  end
end
