defmodule Fornacast.Repo do
  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Postgres)

  use Ecto.Repo,
    otp_app: :fornacast,
    adapter: @adapter
end
