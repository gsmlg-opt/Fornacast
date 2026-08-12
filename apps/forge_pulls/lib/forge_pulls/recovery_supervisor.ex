defmodule ForgePulls.RecoverySupervisor do
  @moduledoc false

  use Supervisor

  if Mix.env() == :test do
    def start_link(opts \\ []) when is_list(opts) do
      case Keyword.get(opts, :name, ForgePulls.Supervisor) do
        nil -> Supervisor.start_link(__MODULE__, opts)
        name -> Supervisor.start_link(__MODULE__, opts, name: name)
      end
    end

    @impl true
    def init(opts) when is_list(opts), do: init_children(opts)
  else
    def start_link(_opts \\ []) do
      Supervisor.start_link(__MODULE__, :production, name: ForgePulls.Supervisor)
    end

    @impl true
    def init(:production), do: init_children([])
  end

  defp init_children(opts) do
    task_supervisor =
      Keyword.get(opts, :task_supervisor, ForgePulls.MergeRecoveryTaskSupervisor)

    reconciler_opts =
      opts
      |> Keyword.get(:reconciler, [])
      |> Keyword.put(:task_supervisor, task_supervisor)

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor},
        id: {Task.Supervisor, task_supervisor}
      ),
      Supervisor.child_spec(
        {ForgePulls.MergeReconciler, reconciler_opts},
        id: ForgePulls.MergeReconciler
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
