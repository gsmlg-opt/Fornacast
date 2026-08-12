defmodule ForgePulls.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ForgePulls.RecoverySupervisor.start_link()
  end
end
