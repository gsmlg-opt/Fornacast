defmodule ForgeReleases.AssetStorage.Manager do
  @moduledoc false

  use GenServer

  alias ExStorageService.{InstanceConfig, Names}
  alias ExStorageService.Storage.Engine

  @default_instance_supervisor ForgeReleases.AssetStorage.InstanceSupervisor
  @initial_backoff_ms 100
  @maximum_backoff_ms 5_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec status() :: :ready | {:not_ready, atom()}
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _reason -> {:not_ready, :manager_unavailable}
  end

  @spec ready?() :: boolean()
  def ready?, do: status() == :ready

  @doc false
  @spec instance_child_spec(InstanceConfig.t()) :: Supervisor.child_spec()
  def instance_child_spec(%InstanceConfig{} = instance_config) do
    instance_config
    |> ExStorageService.child_spec()
    |> Supervisor.child_spec(restart: :temporary, shutdown: 30_000)
  end

  @doc false
  @spec registered_instance(atom() | String.t(), atom()) :: {:ok, pid() | nil} | {:error, atom()}
  def registered_instance(instance_name, registry \\ ExStorageService.Registry) do
    {:ok, GenServer.whereis({:via, Registry, {registry, {instance_name, :instance_supervisor}}})}
  rescue
    ArgumentError -> {:error, :storage_registry_unavailable}
  catch
    :exit, _reason -> {:error, :storage_registry_unavailable}
  end

  @impl true
  def init(options) do
    config = Keyword.fetch!(options, :config)
    instance_supervisor = Keyword.get(options, :instance_supervisor, @default_instance_supervisor)

    state = %{
      config: config,
      instance_supervisor: instance_supervisor,
      status: {:not_ready, :starting},
      instance_pid: nil,
      instance_ref: nil,
      engine_pid: nil,
      engine_ref: nil,
      reconcile_timer: nil,
      reconcile_generation: 0,
      attempt: 0,
      test_observer: nil
    }

    case locate_instance(instance_supervisor, config.instance_config.instance) do
      :absent -> start_initial_instance(state)
      {:ok, instance} -> attach_existing_instance(state, instance)
      {:error, reason} -> {:stop, {:asset_storage_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{instance_ref: reference} = state
      ) do
    state =
      state
      |> clear_engine_monitor()
      |> Map.merge(%{instance_pid: nil, instance_ref: nil})
      |> mark_not_ready(:instance_down)
      |> schedule_reconcile()

    {:noreply, state}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{engine_ref: reference} = state) do
    state =
      state
      |> Map.merge(%{engine_pid: nil, engine_ref: nil})
      |> mark_not_ready(:engine_down)
      |> schedule_reconcile()

    {:noreply, state}
  end

  def handle_info(
        {:reconcile, generation},
        %{reconcile_generation: generation} = state
      ) do
    state = %{state | reconcile_timer: nil}

    case reconcile(state) do
      {:ok, ready} ->
        {:noreply, ready}

      {:error, reason, failed} ->
        {:noreply, failed |> mark_not_ready(reason) |> schedule_reconcile()}
    end
  end

  def handle_info({:reconcile, _stale_generation}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp start_initial_instance(state) do
    case start_instance(state.instance_supervisor, state.config.instance_config) do
      {:ok, instance} ->
        case attach_ready(state, instance) do
          {:ok, ready} ->
            {:ok, ready}

          {:error, reason, failed} ->
            clear_monitors(failed)
            _ = terminate_instance(state.instance_supervisor, instance)
            {:stop, {:asset_storage_start_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:asset_storage_start_failed, reason}}
    end
  end

  defp attach_existing_instance(state, instance) do
    case attach_ready(state, instance) do
      {:ok, ready} ->
        {:ok, ready}

      {:error, reason, failed} ->
        {:ok, failed |> mark_not_ready(reason) |> schedule_reconcile()}
    end
  end

  defp reconcile(state) do
    instance_name = state.config.instance_config.instance

    case locate_instance(state.instance_supervisor, instance_name) do
      {:ok, instance} ->
        attach_ready(state, instance)

      :absent ->
        case start_instance(state.instance_supervisor, state.config.instance_config) do
          {:ok, instance} -> attach_ready(state, instance)
          {:error, reason} -> {:error, normalize_reason(reason), state}
        end

      {:error, reason} ->
        {:error, normalize_reason(reason), state}
    end
  end

  defp start_instance(instance_supervisor, instance_config) do
    DynamicSupervisor.start_child(instance_supervisor, instance_child_spec(instance_config))
  catch
    :exit, reason -> {:error, reason}
  end

  defp terminate_instance(instance_supervisor, instance) do
    DynamicSupervisor.terminate_child(instance_supervisor, instance)
  catch
    :exit, reason -> {:error, reason}
  end

  defp attach_ready(state, instance) do
    state = ensure_instance_monitor(state, instance)

    case owned_engine(instance, state.config.instance_config.instance) do
      {:ok, engine} ->
        {:ok,
         state
         |> ensure_engine_monitor(engine)
         |> cancel_reconcile()
         |> Map.put(:attempt, 0)
         |> set_status(:ready)}

      {:error, reason} ->
        {:error, reason, clear_engine_monitor(state)}
    end
  end

  defp locate_instance(instance_supervisor, instance_name) do
    with {:ok, registered} <- registered_instance(instance_name),
         {:ok, owned} <- owned_instance_pids(instance_supervisor) do
      case owned do
        [] when is_nil(registered) ->
          :absent

        [pid] when pid == registered and is_pid(pid) ->
          {:ok, pid}

        [] ->
          {:error, :instance_name_conflict}

        [_pid] ->
          {:error, :instance_registration_mismatch}

        _multiple ->
          {:error, :multiple_owned_instances}
      end
    end
  end

  defp owned_instance_pids(instance_supervisor) do
    children = DynamicSupervisor.which_children(instance_supervisor)

    {:ok,
     Enum.flat_map(children, fn
       {_id, pid, :supervisor, _modules} when is_pid(pid) -> [pid]
       _child -> []
     end)}
  catch
    :exit, _reason -> {:error, :instance_supervisor_unavailable}
  end

  defp owned_engine(instance, instance_name) do
    with {:ok, registered} <- registered_engine(instance_name) do
      children = Supervisor.which_children(instance)

      engines =
        Enum.flat_map(children, fn
          {_id, pid, :worker, [Engine]} when is_pid(pid) -> [pid]
          _child -> []
        end)

      case engines do
        [engine] when engine == registered -> {:ok, engine}
        [] -> {:error, :engine_not_ready}
        [_engine] -> {:error, :engine_registration_mismatch}
        _multiple -> {:error, :multiple_engines}
      end
    end
  catch
    :exit, _reason -> {:error, :instance_unavailable}
  end

  defp registered_engine(instance_name) do
    {:ok, GenServer.whereis(Names.via(instance_name, :engine))}
  rescue
    ArgumentError -> {:error, :storage_registry_unavailable}
  catch
    :exit, _reason -> {:error, :storage_registry_unavailable}
  end

  defp ensure_instance_monitor(
         %{instance_pid: instance, instance_ref: reference} = state,
         instance
       )
       when is_reference(reference),
       do: state

  defp ensure_instance_monitor(state, instance) do
    state
    |> clear_instance_monitor()
    |> clear_engine_monitor()
    |> Map.merge(%{instance_pid: instance, instance_ref: Process.monitor(instance)})
  end

  defp ensure_engine_monitor(%{engine_pid: engine, engine_ref: reference} = state, engine)
       when is_reference(reference),
       do: state

  defp ensure_engine_monitor(state, engine) do
    state
    |> clear_engine_monitor()
    |> Map.merge(%{engine_pid: engine, engine_ref: Process.monitor(engine)})
  end

  defp clear_monitors(state) do
    state
    |> clear_engine_monitor()
    |> clear_instance_monitor()
  end

  defp clear_instance_monitor(%{instance_ref: reference} = state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    %{state | instance_pid: nil, instance_ref: nil}
  end

  defp clear_instance_monitor(state), do: %{state | instance_pid: nil, instance_ref: nil}

  defp clear_engine_monitor(%{engine_ref: reference} = state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    %{state | engine_pid: nil, engine_ref: nil}
  end

  defp clear_engine_monitor(state), do: %{state | engine_pid: nil, engine_ref: nil}

  defp mark_not_ready(state, reason),
    do: set_status(state, {:not_ready, normalize_reason(reason)})

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    if is_pid(state.test_observer) do
      send(state.test_observer, {:asset_storage_status, status})
    end

    %{state | status: status}
  end

  defp schedule_reconcile(%{reconcile_timer: reference} = state) when is_reference(reference),
    do: state

  defp schedule_reconcile(state) do
    generation = state.reconcile_generation + 1
    timer = Process.send_after(self(), {:reconcile, generation}, backoff(state.attempt))

    %{
      state
      | reconcile_timer: timer,
        reconcile_generation: generation,
        attempt: state.attempt + 1
    }
  end

  defp cancel_reconcile(%{reconcile_timer: reference} = state) when is_reference(reference) do
    Process.cancel_timer(reference, async: false, info: false)

    %{
      state
      | reconcile_timer: nil,
        reconcile_generation: state.reconcile_generation + 1
    }
  end

  defp cancel_reconcile(state), do: state

  defp backoff(attempt) do
    min(@initial_backoff_ms * Integer.pow(2, min(attempt, 10)), @maximum_backoff_ms)
  end

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(_reason), do: :instance_start_failed
end
