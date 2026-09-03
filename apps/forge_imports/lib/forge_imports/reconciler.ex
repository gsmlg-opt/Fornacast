defmodule ForgeImports.Reconciler do
  @moduledoc false

  use GenServer

  alias ForgeImports.{Scheduler, Worker}

  @default_interval_ms 30_000
  @default_batch_size 25
  @default_lease_seconds 2_400
  @default_max_concurrency 1

  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def kick(server \\ __MODULE__), do: GenServer.cast(server, :kick)

  @doc false
  def discovering_run_ids(limit, %DateTime{} = now),
    do: Scheduler.claimable_discovery_ids(now, limit)

  @doc false
  def runnable_repository_item_ids(limit, %DateTime{} = now),
    do: Scheduler.claimable_item_ids(now, limit)

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get(opts, :enabled, true),
      interval_ms: clamp(Keyword.get(opts, :interval_ms, @default_interval_ms), 50, 60_000),
      batch_size: clamp(Keyword.get(opts, :batch_size, @default_batch_size), 1, 100),
      lease_seconds: clamp(Keyword.get(opts, :lease_seconds, @default_lease_seconds), 2, 2_400),
      max_concurrency:
        clamp(
          Keyword.get(
            opts,
            :max_concurrency,
            Application.get_env(:forge_imports, :recovery_max_concurrency, @default_max_concurrency)
          ),
          1,
          100
        ),
      client: Keyword.get(opts, :client, ForgeImports.GitHub.Client),
      client_options: Keyword.get(opts, :client_options, []),
      keyring: Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring()),
      repository_worker: Keyword.get(opts, :repository_worker, ForgeImports.RepositoryWorker),
      repository_worker_options: Keyword.get(opts, :repository_worker_options, []),
      sandbox_owner: sandbox_owner(opts),
      task_supervisor: Keyword.get(opts, :task_supervisor, ForgeImports.TaskSupervisor),
      tasks: %{},
      timer: nil,
      rescan_requested: false
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, %{enabled: true} = state) do
    {:noreply, dispatch(state)}
  end

  def handle_continue(:startup, state), do: {:noreply, state}

  @impl true
  def handle_cast(:kick, %{enabled: true} = state) do
    {:noreply, dispatch(%{state | rescan_requested: true})}
  end

  def handle_cast(:kick, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, %{enabled: true} = state), do: {:noreply, dispatch(state)}
  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:scan, token}, %{enabled: true, timer: {_timer, token}} = state) do
    {:noreply, dispatch(%{state | timer: nil})}
  end

  def handle_info({:scan, _token}, state), do: {:noreply, state}

  def handle_info({reference, _result}, %{tasks: tasks} = state) do
    case find_task(tasks, reference) do
      {key, task} ->
        Process.demonitor(task.ref, [:flush])
        {:noreply, finish_task(state, key)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{tasks: tasks} = state) do
    case find_task(tasks, reference) do
      {key, _task} ->
        {:noreply, finish_task(state, key)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(%{enabled: false} = state), do: state

  defp dispatch(state) do
    state
    |> fill_slots()
    |> finalize_dispatch()
  end

  defp fill_slots(state) do
    available = state.max_concurrency - map_size(state.tasks)

    if available <= 0 do
      state
    else
      now = DateTime.utc_now(:second)
      work = claimable_work(state, available, now)
      Enum.reduce(work, state, &start_worker/2)
    end
  end

  defp claimable_work(state, limit, now) do
    inflight = MapSet.new(Map.keys(state.tasks))

    discovery_work =
      now
      |> Scheduler.claimable_discovery_ids(state.batch_size)
      |> Enum.reject(fn run_id -> MapSet.member?(inflight, {:discovery, run_id}) end)
      |> Enum.map(&{:discovery, &1})

    item_work =
      now
      |> Scheduler.claimable_item_ids(state.batch_size)
      |> Enum.reject(fn item_id -> MapSet.member?(inflight, {:item, item_id}) end)
      |> Enum.map(&{:item, &1})

    (discovery_work ++ item_work)
    |> Enum.take(limit)
  end

  defp start_worker({kind, id}, state) do
    key = {kind, id}
    owner = generated_owner(kind)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        allow_repo_sandbox(state.sandbox_owner)
        run_worker(kind, id, owner, state)
      end)

    %{state | tasks: Map.put(state.tasks, key, task)}
  rescue
    RuntimeError -> state
  end

  defp run_worker(:discovery, run_id, owner, state) do
    Worker.run_discovery(run_id, owner,
      lease_seconds: state.lease_seconds,
      client: state.client,
      client_options: state.client_options,
      keyring: state.keyring
    )
  end

  defp run_worker(:item, item_id, owner, state) do
    Worker.run(item_id, owner,
      repository_worker: state.repository_worker,
      repository_worker_options: repository_worker_options(state)
    )
  end

  defp finish_task(state, key) do
    state
    |> Map.update!(:tasks, &Map.delete(&1, key))
    |> dispatch()
  end

  defp finalize_dispatch(%{rescan_requested: true} = state) do
    state
    |> Map.put(:rescan_requested, false)
    |> dispatch()
  end

  defp finalize_dispatch(%{tasks: tasks} = state) when map_size(tasks) > 0 do
    schedule(state)
  end

  defp finalize_dispatch(state), do: schedule(state)

  defp schedule(%{enabled: true} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:scan, token}, state.interval_ms)
    %{state | timer: {timer, token}}
  end

  defp schedule(state), do: state

  defp repository_worker_options(state) do
    minimum = max(state.lease_seconds, 2)

    Keyword.update(
      state.repository_worker_options,
      :lease_seconds,
      minimum,
      fn
        value when is_integer(value) -> max(value, 2)
        value -> value
      end
    )
  end

  defp generated_owner(:discovery) do
    "github-discovery-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp generated_owner(:item) do
    "github-import-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp find_task(tasks, reference) do
    Enum.find_value(tasks, :error, fn {key, %Task{ref: ref} = task} ->
      if ref == reference, do: {key, task}
    end)
  end

  defp clamp(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp clamp(_value, _min, max), do: max

  defp allow_repo_sandbox(owner) when is_pid(owner) do
    :ok = Ecto.Adapters.SQL.Sandbox.allow(Fornacast.Repo, owner, self())
  end

  defp allow_repo_sandbox(_owner), do: :ok

  if Mix.env() == :test do
    defp sandbox_owner(opts) do
      Keyword.get(opts, :sandbox_owner) ||
        :persistent_term.get({ForgeImports.Reconciler, :sandbox_owner}, nil)
    end
  else
    defp sandbox_owner(opts), do: Keyword.get(opts, :sandbox_owner)
  end
end
