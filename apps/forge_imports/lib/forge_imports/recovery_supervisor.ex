defmodule ForgeImports.RecoverySupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, ForgeImports.TaskSupervisor)
    reconciler_name = Keyword.get(opts, :reconciler_name, ForgeImports.Reconciler)

    reconciler_opts =
      opts
      |> Keyword.drop([:task_supervisor, :reconciler_name])
      |> Keyword.put(:task_supervisor, task_supervisor)
      |> Keyword.put(:name, reconciler_name)

    children = [
      {Task.Supervisor, name: task_supervisor, max_children: 1},
      {ForgeImports.Reconciler, reconciler_opts}
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 5,
      max_seconds: 30
    )
  end
end
