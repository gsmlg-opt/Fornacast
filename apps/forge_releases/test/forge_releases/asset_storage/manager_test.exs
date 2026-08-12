defmodule ForgeReleases.AssetStorage.ManagerTest do
  use ExUnit.Case, async: false

  alias ExStorageService.Names
  alias ForgeReleases.AssetStorage.Manager

  @instance :fornacast_release_assets

  test "the exact instance is ready, owned, and has only its Engine child" do
    assert Manager.status() == :ready
    assert Manager.ready?()

    instance = instance_pid()
    assert is_pid(instance)

    assert Enum.any?(
             DynamicSupervisor.which_children(ForgeReleases.AssetStorage.InstanceSupervisor),
             fn {_id, pid, _type, _modules} -> pid == instance end
           )

    assert [{_id, engine, :worker, [ExStorageService.Storage.Engine]}] =
             Supervisor.which_children(instance)

    assert is_pid(engine)
    refute Application.spec(:ex_storage_service_s3)
  end

  test "the ESS child spec is temporary with a bounded shutdown" do
    config = ForgeReleases.AssetStorage.Config.load!()
    spec = Manager.instance_child_spec(config.instance_config)

    assert spec.restart == :temporary
    assert spec.shutdown == 30_000
  end

  test "a cold start failure stops the manager" do
    config = ForgeReleases.AssetStorage.Config.load!()

    assert {:stop, {:asset_storage_start_failed, :instance_supervisor_unavailable}} =
             Manager.init(config: config, instance_supervisor: :missing_instance_supervisor)
  end

  test "a missing ESS Registry is normalized instead of crashing the manager" do
    assert {:error, :storage_registry_unavailable} =
             Manager.registered_instance(:fornacast_release_assets, :missing_storage_registry)
  end

  test "Engine loss becomes not-ready and recovers inside the same instance" do
    instance = fresh_instance()
    old_engine = engine_pid(instance)

    observe_manager()

    Process.exit(old_engine, :kill)

    assert_receive {:asset_storage_status, {:not_ready, :engine_down}}, 1_000

    assert_eventually(fn ->
      new_engine = engine_pid(instance)

      is_pid(new_engine) and new_engine != old_engine and Process.alive?(new_engine) and
        Manager.ready?()
    end)

    assert instance_pid() == instance
  end

  test "instance loss becomes not-ready and restarts without application or Concord loss" do
    release_supervisor = Process.whereis(ForgeReleases.Supervisor)
    concord_supervisor = Process.whereis(Concord.Supervisor)
    vsr_supervisor = Process.whereis(Concord.Engine.VSR.Supervisor)
    old_instance = instance_pid()

    assert is_pid(release_supervisor)
    assert is_pid(concord_supervisor)
    assert is_pid(vsr_supervisor)

    observe_manager()

    Process.exit(old_instance, :kill)

    assert_receive {:asset_storage_status, {:not_ready, :instance_down}}, 1_000

    assert_eventually(fn ->
      new_instance = instance_pid()

      is_pid(new_instance) and new_instance != old_instance and Process.alive?(new_instance) and
        Manager.ready?()
    end)

    assert Process.whereis(ForgeReleases.Supervisor) == release_supervisor
    assert Process.whereis(Concord.Supervisor) == concord_supervisor
    assert Process.whereis(Concord.Engine.VSR.Supervisor) == vsr_supervisor
  end

  test "manager restart during Engine recovery attaches once and becomes ready" do
    instance = fresh_instance()
    old_engine = engine_pid(instance)
    old_manager = Process.whereis(Manager)

    Process.exit(old_engine, :kill)
    Process.exit(old_manager, :kill)

    assert_eventually(fn ->
      manager = Process.whereis(Manager)
      engine = engine_pid(instance)

      is_pid(manager) and manager != old_manager and is_pid(engine) and engine != old_engine and
        Manager.ready?()
    end)

    assert instance_pid() == instance

    assert [{_id, ^instance, :supervisor, _modules}] =
             DynamicSupervisor.which_children(ForgeReleases.AssetStorage.InstanceSupervisor)

    assert_manager_clean(instance)
  end

  test "rapid Engine transitions converge without duplicate instances or stale recovery" do
    instance = fresh_instance()
    first_engine = engine_pid(instance)
    Process.exit(first_engine, :kill)

    assert_eventually(fn ->
      engine = engine_pid(instance)
      is_pid(engine) and engine != first_engine
    end)

    second_engine = engine_pid(instance)
    Process.exit(second_engine, :kill)

    assert_eventually(fn ->
      engine = engine_pid(instance)
      is_pid(engine) and engine != second_engine and Manager.ready?()
    end)

    Process.sleep(250)

    assert Manager.status() == :ready
    assert instance_pid() == instance

    assert [{_id, ^instance, :supervisor, _modules}] =
             DynamicSupervisor.which_children(ForgeReleases.AssetStorage.InstanceSupervisor)

    assert_manager_clean(instance)
  end

  defp instance_pid do
    GenServer.whereis(Names.instance_supervisor(@instance))
  end

  defp fresh_instance do
    old_instance = instance_pid()
    Process.exit(old_instance, :kill)

    assert_eventually(fn ->
      instance = instance_pid()
      is_pid(instance) and instance != old_instance and Manager.ready?()
    end)

    instance_pid()
  end

  defp observe_manager do
    observer = self()
    :sys.replace_state(Manager, &Map.put(&1, :test_observer, observer))
  end

  defp assert_manager_clean(instance) do
    state = :sys.get_state(Manager)
    assert state.status == :ready
    assert state.reconcile_timer == nil
    assert state.attempt == 0
    assert state.instance_pid == instance
    assert state.engine_pid == engine_pid(instance)
    assert is_reference(state.instance_ref)
    assert is_reference(state.engine_ref)
  end

  defp engine_pid(instance) when is_pid(instance) do
    instance
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, :worker, [ExStorageService.Storage.Engine]} -> pid
      _child -> nil
    end)
  catch
    :exit, _reason -> nil
  end

  defp engine_pid(_instance), do: nil

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true before timeout")
end
