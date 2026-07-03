defmodule FornacastWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FornacastWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: FornacastWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
