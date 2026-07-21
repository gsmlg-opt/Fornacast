defmodule FornacastAPI.Application do
  use Application

  @impl true
  def start(_type, _args) do
    trusted_proxy_cidrs =
      :fornacast_api
      |> Application.get_env(:trusted_proxy_cidrs, [])
      |> FornacastAPI.ClientIP.parse_cidrs!()

    Application.put_env(:fornacast_api, :trusted_proxy_cidrs, trusted_proxy_cidrs)

    Supervisor.start_link(
      [FornacastAPI.RateLimit, FornacastAPI.Endpoint],
      strategy: :one_for_one,
      name: FornacastAPI.Supervisor
    )
  end
end
