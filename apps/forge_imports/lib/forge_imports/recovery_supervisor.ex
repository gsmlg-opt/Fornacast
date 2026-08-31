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

    cleanup_task_supervisor =
      Keyword.get(opts, :cleanup_task_supervisor, ForgeImports.CleanupTaskSupervisor)

    cleanup_reconciler_name =
      Keyword.get(opts, :cleanup_reconciler_name, ForgeImports.CleanupReconciler)

    reconciler_opts =
      opts
      |> Keyword.drop([
        :task_supervisor,
        :reconciler_name,
        :cleanup_task_supervisor,
        :cleanup_reconciler_name,
        :cleanup_enabled,
        :cleanup_options
      ])
      |> Keyword.put(:task_supervisor, task_supervisor)
      |> Keyword.put(:name, reconciler_name)

    cleanup_enabled = Keyword.get(opts, :cleanup_enabled, false)

    cleanup_opts = [
      name: cleanup_reconciler_name,
      task_supervisor: cleanup_task_supervisor,
      enabled: cleanup_enabled,
      cleanup_options: Keyword.get(opts, :cleanup_options, [])
    ]

    import_pair =
      Supervisor.child_spec(
        {ForgeImports.RecoverySupervisor.Pair,
         task_supervisor: task_supervisor,
         reconciler: ForgeImports.Reconciler,
         reconciler_opts: reconciler_opts,
         reconciler_id: reconciler_name},
        id: :import_recovery_pair
      )

    cleanup_pairs =
      if cleanup_enabled do
        [
          Supervisor.child_spec(
            {ForgeImports.RecoverySupervisor.Pair,
             task_supervisor: cleanup_task_supervisor,
             reconciler: ForgeImports.CleanupReconciler,
             reconciler_opts: cleanup_opts,
             reconciler_id: cleanup_reconciler_name},
            id: :cleanup_recovery_pair
          )
        ]
      else
        []
      end

    children = [import_pair] ++ cleanup_pairs

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 30
    )
  end
end

defmodule ForgeImports.RecoverySupervisor.Pair do
  @moduledoc false

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    reconciler = Keyword.fetch!(opts, :reconciler)
    reconciler_opts = Keyword.fetch!(opts, :reconciler_opts)
    reconciler_id = Keyword.fetch!(opts, :reconciler_id)

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor, max_children: 1},
        id: task_supervisor
      ),
      Supervisor.child_spec({reconciler, reconciler_opts}, id: reconciler_id)
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 5,
      max_seconds: 30
    )
  end
end
