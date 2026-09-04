defmodule ForgeMirrors.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: ForgeMirrors.TaskSupervisor},
      ForgeMirrors.OperationReconciler,
      ForgeMirrors.OutboxDispatcher,
      ForgeMirrors.PeriodicReconciler
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ForgeMirrors.Supervisor)
  end
end
