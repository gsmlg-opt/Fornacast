defmodule ForgePulls.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: ForgePulls.MergeRecoveryTaskSupervisor},
      ForgePulls.MergeReconciler
    ]

    Supervisor.start_link(children, strategy: :one_for_all, name: ForgePulls.Supervisor)
  end
end
