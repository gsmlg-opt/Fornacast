defmodule ForgePulls.MergeReconciler do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias ForgePulls.MergeOperation
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @batch_size 50
  @interval_ms 30_000
  @runtime_ms 30_000
  @terminal_states [:completed, :failed]

  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc false
  def interval_ms, do: @interval_ms

  @doc false
  def runtime_ms, do: @runtime_ms

  @impl true
  def init(opts) do
    state = %{
      task: nil,
      runtime_timer: nil,
      tick_timer: nil,
      task_supervisor:
        Keyword.get(opts, :task_supervisor, ForgePulls.MergeRecoveryTaskSupervisor),
      task_fun: task_fun(opts),
      interval_ms: bounded_test_timeout(opts, :interval_ms, @interval_ms),
      runtime_ms: bounded_test_timeout(opts, :runtime_ms, @runtime_ms)
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state) do
    {:noreply, state |> schedule_tick() |> start_task()}
  end

  @impl true
  def handle_info(:tick, state) do
    state = schedule_tick(state)
    {:noreply, if(state.task == nil, do: start_task(state), else: state)}
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, clear_task(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, clear_task(state)}
  end

  def handle_info({:runtime_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    _result = Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    {:noreply, clear_task(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def reconcile_pending_repositories do
    MergeOperation
    |> join(:inner, [operation], repository in Repository,
      on: repository.id == operation.repository_id
    )
    |> where(
      [operation, repository],
      operation.state not in ^@terminal_states and repository.lifecycle == :ready and
        is_nil(repository.deleted_at)
    )
    |> group_by([operation, _repository], operation.repository_id)
    |> order_by([operation, _repository], desc: operation.repository_id)
    |> limit(@batch_size)
    |> select([operation, _repository], operation.repository_id)
    |> Repo.all()
    |> Enum.each(fn repository_id ->
      repository =
        Repository
        |> where(
          [repository],
          repository.id == ^repository_id and repository.lifecycle == :ready and
            is_nil(repository.deleted_at)
        )
        |> Repo.one()

      case repository do
        %Repository{} = repository -> _result = ForgePulls.reconcile_repository(repository, [])
        nil -> :ok
      end
    end)

    :ok
  end

  defp start_task(%{task: nil} = state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, state.task_fun)
    runtime_timer = Process.send_after(self(), {:runtime_timeout, task.ref}, state.runtime_ms)
    %{state | task: task, runtime_timer: runtime_timer}
  end

  defp schedule_tick(state) do
    timer = Process.send_after(self(), :tick, state.interval_ms)
    %{state | tick_timer: timer}
  end

  defp clear_task(state) do
    cancel_timer(state.runtime_timer)
    %{state | task: nil, runtime_timer: nil}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _result = Process.cancel_timer(timer)
    :ok
  end

  if Mix.env() == :test do
    defp task_fun(opts), do: Keyword.get(opts, :task, &reconcile_pending_repositories/0)

    defp bounded_test_timeout(opts, key, maximum) do
      case Keyword.get(opts, key, maximum) do
        timeout when is_integer(timeout) and timeout > 0 -> min(timeout, maximum)
        _invalid -> maximum
      end
    end
  else
    defp task_fun(_opts), do: &reconcile_pending_repositories/0
    defp bounded_test_timeout(_opts, _key, maximum), do: maximum
  end
end
