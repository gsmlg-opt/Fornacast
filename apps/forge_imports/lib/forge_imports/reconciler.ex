defmodule ForgeImports.Reconciler do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias ForgeImports.{DiscoveryWorker, ImportRun}
  alias Fornacast.Repo

  @default_interval_ms 30_000
  @default_batch_size 25
  @default_lease_seconds 2_400

  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def kick(server \\ __MODULE__), do: GenServer.cast(server, :kick)

  @doc false
  def discovering_run_ids(limit, %DateTime{} = now)
      when is_integer(limit) and limit in 1..100 do
    now = DateTime.truncate(now, :second)

    ImportRun
    |> where(
      [run],
      run.state == :discovering and
        (is_nil(run.next_attempt_at) or run.next_attempt_at <= ^now) and
        (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)
    )
    |> order_by([run], asc: run.id)
    |> limit(^limit)
    |> select([run], run.id)
    |> Repo.all()
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get(opts, :enabled, true),
      interval_ms: clamp(Keyword.get(opts, :interval_ms, @default_interval_ms), 50, 60_000),
      batch_size: clamp(Keyword.get(opts, :batch_size, @default_batch_size), 1, 100),
      lease_seconds: clamp(Keyword.get(opts, :lease_seconds, @default_lease_seconds), 1, 2_400),
      client: Keyword.get(opts, :client, ForgeImports.GitHub.Client),
      client_options: Keyword.get(opts, :client_options, []),
      keyring: Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring()),
      task_supervisor: Keyword.get(opts, :task_supervisor, ForgeImports.TaskSupervisor),
      task: nil,
      timer: nil,
      scan_queued: false,
      rescan_requested: false
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, %{enabled: true} = state) do
    {:noreply, queue_scan(state)}
  end

  def handle_continue(:startup, state), do: {:noreply, state}

  @impl true
  def handle_cast(:kick, %{enabled: true, task: nil} = state) do
    state = state |> cancel_scheduled_scan() |> queue_scan()
    {:noreply, state}
  end

  def handle_cast(:kick, %{enabled: true} = state),
    do: {:noreply, %{state | rescan_requested: true}}

  def handle_cast(:kick, state), do: {:noreply, state}

  @impl true
  def handle_info(:scan, %{enabled: true, task: nil} = state) do
    start_scan(%{state | scan_queued: false, timer: nil})
  end

  def handle_info(:scan, %{enabled: true} = state) do
    {:noreply, %{state | scan_queued: false, rescan_requested: true}}
  end

  def handle_info(
        {:scan, token},
        %{enabled: true, task: nil, timer: {_timer, token}} = state
      ) do
    start_scan(%{state | timer: nil})
  end

  def handle_info(
        {:scan, token},
        %{enabled: true, timer: {_timer, token}} = state
      ) do
    {:noreply, %{state | timer: nil, rescan_requested: true}}
  end

  def handle_info({:scan, _token}, state), do: {:noreply, state}
  def handle_info(:scan, state), do: {:noreply, %{state | scan_queued: false}}

  def handle_info({reference, _result}, %{task: %Task{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, after_scan(%{state | task: nil})}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{task: %Task{ref: reference}} = state
      ) do
    {:noreply, after_scan(%{state | task: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reconcile_batch(state) do
    state.batch_size
    |> discovering_run_ids(DateTime.utc_now(:second))
    |> Enum.map(fn run_id ->
      DiscoveryWorker.perform(run_id,
        lease_seconds: state.lease_seconds,
        client: state.client,
        client_options: state.client_options,
        keyring: state.keyring
      )
    end)
  end

  defp start_scan(state) do
    case start_scan_task(state) do
      {:ok, task} -> {:noreply, %{state | task: task}}
      {:error, :max_children} -> {:noreply, schedule(state)}
    end
  end

  defp start_scan_task(state) do
    {:ok, Task.Supervisor.async_nolink(state.task_supervisor, fn -> reconcile_batch(state) end)}
  rescue
    RuntimeError -> {:error, :max_children}
  end

  defp queue_scan(%{scan_queued: true} = state), do: state

  defp queue_scan(state) do
    send(self(), :scan)
    %{state | scan_queued: true}
  end

  defp after_scan(%{enabled: true, rescan_requested: true} = state) do
    state
    |> Map.put(:rescan_requested, false)
    |> queue_scan()
  end

  defp after_scan(state), do: schedule(state)

  defp schedule(%{enabled: true} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:scan, token}, state.interval_ms)
    %{state | timer: {timer, token}}
  end

  defp schedule(state), do: state

  defp cancel_scheduled_scan(%{timer: {reference, _token}} = state) do
    Process.cancel_timer(reference)
    %{state | timer: nil}
  end

  defp cancel_scheduled_scan(state), do: state

  defp clamp(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp clamp(_value, _min, max), do: max
end
