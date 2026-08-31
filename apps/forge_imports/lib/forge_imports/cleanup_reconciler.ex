defmodule ForgeImports.CleanupReconciler do
  @moduledoc false

  use GenServer

  alias ForgeImports.RepositoryCleanup

  @kinds [:remote_quarantine, :unpublished_shadow, :replacement_tombstone]
  @settlement_margin_ms 1_000

  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def kick(server \\ __MODULE__), do: GenServer.cast(server, :kick)

  def interval_ms do
    Fornacast.Config.repository_cleanup().interval_ms
  end

  def runtime_ms do
    Fornacast.Config.repository_cleanup().deadline_ms
  end

  @doc false
  def kinds_after(last_kind) do
    case Enum.find_index(@kinds, &(&1 == last_kind)) do
      nil -> @kinds
      index -> Enum.drop(@kinds, index + 1) ++ Enum.take(@kinds, index + 1)
    end
  end

  @doc false
  def reconcile_once(last_kind \\ nil, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    deadline_ms = Keyword.get(opts, :deadline_ms, runtime_ms())

    monotonic_ms =
      Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    absolute_deadline =
      Keyword.get_lazy(opts, :absolute_deadline, fn -> monotonic_ms.() + deadline_ms end)

    repository_cleanup = Keyword.get(opts, :repository_cleanup, RepositoryCleanup)
    raw_cursors = Keyword.get(opts, :raw_cursors, %{})

    Enum.reduce_while(kinds_after(last_kind), last_kind, fn kind, _cursor ->
      kind_opts = Keyword.put(opts, :raw_cursor, Map.get(raw_cursors, kind))

      case repository_cleanup.reconcile_kind(kind, now, absolute_deadline, kind_opts) do
        :none -> {:cont, kind}
        _attempted -> {:halt, kind}
      end
    end)
  end

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)
    runtime_ms = Keyword.get(opts, :runtime_ms, runtime_ms())
    operation_deadline_ms = operation_deadline_ms(opts, runtime_ms)

    unless is_integer(runtime_ms) and runtime_ms > 1 and is_integer(operation_deadline_ms) and
             operation_deadline_ms > 0 and operation_deadline_ms < runtime_ms do
      raise ArgumentError,
            "cleanup operation deadline must be positive and earlier than the hard runtime"
    end

    state = %{
      enabled: enabled,
      task_supervisor: Keyword.get(opts, :task_supervisor, ForgeImports.CleanupTaskSupervisor),
      task: nil,
      task_timeout: nil,
      timer: nil,
      last_kind: Keyword.get(opts, :last_kind),
      raw_cursors: Keyword.get(opts, :raw_cursors, %{}),
      repository_cleanup: Keyword.get(opts, :repository_cleanup, RepositoryCleanup),
      interval_ms: Keyword.get(opts, :interval_ms, interval_ms()),
      operation_deadline_ms: operation_deadline_ms,
      settlement_margin_ms: runtime_ms - operation_deadline_ms,
      runtime_ms: runtime_ms,
      cleanup_options: Keyword.get(opts, :cleanup_options, [])
    }

    {:ok, if(enabled, do: queue_scan(state), else: state)}
  end

  @impl true
  def handle_cast(:kick, %{enabled: true, task: nil} = state),
    do: {:noreply, state |> cancel_timer() |> queue_scan()}

  def handle_cast(:kick, state), do: {:noreply, state}

  @impl true
  def handle_info(:scan, %{enabled: true, task: nil} = state) do
    parent = self()

    monotonic_ms =
      Keyword.get(state.cleanup_options, :monotonic_ms, fn ->
        System.monotonic_time(:millisecond)
      end)

    scan_started_at = monotonic_ms.()
    operation_deadline = scan_started_at + state.operation_deadline_ms
    watchdog_deadline = scan_started_at + state.runtime_ms

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        run_before_reconcile_hook(state.cleanup_options)

        cleanup_options =
          state.cleanup_options
          |> Keyword.merge(deadline_ms: state.operation_deadline_ms)
          |> Keyword.put(:absolute_deadline, operation_deadline)
          |> Keyword.put(:repository_cleanup, state.repository_cleanup)
          |> Keyword.put(:raw_cursors, state.raw_cursors)
          |> Keyword.put(:selection_observer, fn kind ->
            send(parent, {:cleanup_cursor, self(), kind})
          end)
          |> Keyword.put(:raw_cursor_observer, fn kind, cursor ->
            send(parent, {:cleanup_raw_cursor, self(), kind, cursor})
            send(self(), {:cleanup_task_raw_cursor, kind, cursor})
          end)

        cursor =
          reconcile_once(
            state.last_kind,
            cleanup_options
          )

        send(parent, {:cleanup_cursor, self(), cursor})
        {:cleanup_scan, cursor, collect_task_raw_cursors(state.raw_cursors)}
      end)

    watchdog_delay = max(watchdog_deadline - monotonic_ms.(), 0)
    task_timeout = Process.send_after(self(), {:task_timeout, task.ref}, watchdog_delay)

    {:noreply, %{state | task: task, task_timeout: task_timeout, timer: nil}}
  rescue
    RuntimeError -> {:noreply, schedule(%{state | timer: nil})}
  end

  def handle_info({:cleanup_cursor, pid, cursor}, %{task: %Task{pid: pid}} = state),
    do: {:noreply, %{state | last_kind: cursor}}

  def handle_info(
        {:cleanup_raw_cursor, pid, kind, cursor},
        %{task: %Task{pid: pid}} = state
      ) do
    {:noreply, %{state | raw_cursors: apply_raw_cursor(state.raw_cursors, kind, cursor)}}
  end

  def handle_info(
        {reference, {:cleanup_scan, last_kind, raw_cursors}},
        %{task: %Task{ref: reference}} = state
      ) do
    Process.demonitor(reference, [:flush])
    {:noreply, finish_scan(state, last_kind, raw_cursors)}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{task: %Task{ref: reference}} = state
      ),
      do: {:noreply, state |> cancel_task_timeout() |> Map.put(:task, nil) |> schedule()}

  def handle_info({:task_timeout, reference}, %{task: %Task{ref: reference} = task} = state) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, {:cleanup_scan, last_kind, raw_cursors}} ->
        {:noreply, finish_scan(state, last_kind, raw_cursors)}

      _killed_or_crashed ->
        state = drain_task_progress(state, task.pid)
        {:noreply, finish_scan(state, state.last_kind, state.raw_cursors)}
    end
  end

  def handle_info({:scan, token}, %{timer: {_timer, token}} = state),
    do: handle_info(:scan, %{state | timer: nil})

  def handle_info(_message, state), do: {:noreply, state}

  if Mix.env() == :test do
    defp run_before_reconcile_hook(opts) do
      case Keyword.get(opts, :before_reconcile_hook) do
        hook when is_function(hook, 0) -> hook.()
        _none -> :ok
      end
    end
  else
    defp run_before_reconcile_hook(_opts), do: :ok
  end

  defp queue_scan(state) do
    send(self(), :scan)
    state
  end

  defp schedule(%{enabled: true} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:scan, token}, state.interval_ms)
    %{state | timer: {timer, token}}
  end

  defp schedule(state), do: state

  defp cancel_timer(%{timer: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state

  defp cancel_task_timeout(%{task_timeout: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | task_timeout: nil}
  end

  defp cancel_task_timeout(state), do: state

  defp collect_task_raw_cursors(raw_cursors) do
    receive do
      {:cleanup_task_raw_cursor, kind, cursor} ->
        raw_cursors
        |> apply_raw_cursor(kind, cursor)
        |> collect_task_raw_cursors()
    after
      0 -> raw_cursors
    end
  end

  defp drain_task_progress(state, pid) do
    receive do
      {:cleanup_cursor, ^pid, cursor} ->
        drain_task_progress(%{state | last_kind: cursor}, pid)

      {:cleanup_raw_cursor, ^pid, kind, cursor} ->
        raw_cursors = apply_raw_cursor(state.raw_cursors, kind, cursor)
        drain_task_progress(%{state | raw_cursors: raw_cursors}, pid)
    after
      0 -> state
    end
  end

  defp finish_scan(state, last_kind, raw_cursors) do
    state
    |> cancel_task_timeout()
    |> Map.put(:task, nil)
    |> Map.put(:last_kind, last_kind)
    |> Map.put(:raw_cursors, raw_cursors)
    |> schedule()
  end

  defp apply_raw_cursor(raw_cursors, kind, nil), do: Map.delete(raw_cursors, kind)
  defp apply_raw_cursor(raw_cursors, kind, cursor), do: Map.put(raw_cursors, kind, cursor)

  defp operation_deadline_ms(opts, runtime_ms) do
    if Keyword.has_key?(opts, :operation_deadline_ms) do
      Keyword.fetch!(opts, :operation_deadline_ms)
    else
      margin = min(@settlement_margin_ms, max(div(runtime_ms, 10), 1))
      runtime_ms - margin
    end
  end
end
