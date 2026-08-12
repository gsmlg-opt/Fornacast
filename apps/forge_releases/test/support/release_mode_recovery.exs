defmodule ForgeReleases.ReleaseModeRecoveryProbe do
  @instance :fornacast_release_assets

  def run do
    configure_isolated_storage!()

    release_applications =
      FornacastUmbrella.MixProject.releases()
      |> Keyword.fetch!(:fornacast)
      |> Keyword.fetch!(:applications)

    host_mode = Keyword.fetch!(release_applications, :forge_releases)
    storage_mode = Keyword.fetch!(release_applications, :ex_storage_service)

    assert!(host_mode == :permanent, {:unexpected_host_mode, host_mode})
    assert!(storage_mode == :temporary, {:unexpected_storage_mode, storage_mode})

    :ok = load_database_independent_host!()
    {:ok, _started} = Application.ensure_all_started(:ex_storage_service, storage_mode)
    :ok = Application.start(:forge_releases, host_mode)

    assert!(Process.whereis(Fornacast.Repo) == nil, :database_started)
    assert_application_mode!(:forge_releases, :permanent)
    assert_application_mode!(:ex_storage_service, :temporary)

    release_supervisor = required_process!(ForgeReleases.Supervisor)
    manager = required_process!(ForgeReleases.AssetStorage.Manager)
    vsr_supervisor = required_process!(Concord.Engine.VSR.Supervisor)
    old_storage_supervisor = required_process!(ExStorageService.Supervisor)
    old_registry = required_process!(ExStorageService.Registry)
    old_instance = required_instance!()

    assert!(ForgeReleases.AssetStorage.Manager.ready?(), :manager_not_ready_before_failure)

    Process.exit(old_storage_supervisor, :kill)

    wait_until!(fn ->
      storage_supervisor = Process.whereis(ExStorageService.Supervisor)
      registry = Process.whereis(ExStorageService.Registry)
      instance = instance_pid()

      is_pid(storage_supervisor) and storage_supervisor != old_storage_supervisor and
        is_pid(registry) and registry != old_registry and is_pid(instance) and
        instance != old_instance and ForgeReleases.AssetStorage.Manager.ready?()
    end)

    assert!(Process.whereis(ForgeReleases.Supervisor) == release_supervisor, :host_restarted)
    assert!(Process.whereis(ForgeReleases.AssetStorage.Manager) == manager, :manager_restarted)
    assert!(Process.whereis(Concord.Engine.VSR.Supervisor) == vsr_supervisor, :vsr_restarted)
    assert!(Process.whereis(Fornacast.Repo) == nil, :database_started)
    assert_application_mode!(:forge_releases, :permanent)
    assert_application_mode!(:ex_storage_service, :temporary)

    IO.puts("release-mode-recovery:ok")
  end

  defp configure_isolated_storage! do
    root =
      System.fetch_env!("FORNACAST_RELEASE_RECOVERY_TMP")
      |> Path.join("release-assets")
      |> Path.expand()

    Application.put_env(:fornacast, :release_asset_storage_root, root)

    Application.put_env(:concord, :data_dir, Path.join(root, "concord"))

    Application.put_env(:concord, :vsr,
      group_id: :ex_storage_service_metadata,
      replica_id: node(),
      members: [%{id: node(), endpoint: node()}],
      storage: :file,
      bootstrap: false
    )

    Application.put_env(:concord, :turso, enabled: false)

    for {key, path} <- [
          data_root: root,
          blob_root: Path.join(root, "cas"),
          tmp_root: Path.join(root, "tmp"),
          ra_root: Path.join(root, "ra"),
          metadata_root: Path.join(root, "concord")
        ] do
      Application.put_env(:ex_storage_service, key, path)
    end
  end

  defp load_database_independent_host! do
    spec =
      :forge_releases
      |> Application.spec()
      |> Keyword.update!(:applications, &List.delete(&1, :fornacast))
      |> Keyword.reject(fn {_key, value} -> value == :undefined end)

    :ok = Application.unload(:forge_releases)
    :ok = :application.load({:application, :forge_releases, spec})

    assert!(
      :fornacast not in Application.spec(:forge_releases, :applications),
      :database_dependency_retained
    )

    :ok
  end

  defp assert_application_mode!(application, expected) do
    started =
      :application_controller.info()
      |> Keyword.fetch!(:started)

    assert!(
      List.keyfind(started, application, 0) == {application, expected},
      {:unexpected_started_application, application, started}
    )
  end

  defp required_process!(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> pid
      nil -> raise "required process is absent: #{inspect(name)}"
    end
  end

  defp required_instance! do
    case instance_pid() do
      pid when is_pid(pid) -> pid
      nil -> raise "release-asset instance is absent"
    end
  end

  defp instance_pid do
    GenServer.whereis(ExStorageService.Names.instance_supervisor(@instance))
  rescue
    ArgumentError -> nil
  catch
    :exit, _reason -> nil
  end

  defp wait_until!(fun, attempts \\ 200)

  defp wait_until!(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until!(fun, attempts - 1)
    end
  end

  defp wait_until!(_fun, 0), do: raise("release-mode recovery timed out")

  defp assert!(true, _reason), do: :ok
  defp assert!(false, reason), do: raise("probe assertion failed: #{inspect(reason)}")
end

try do
  ForgeReleases.ReleaseModeRecoveryProbe.run()
  System.halt(0)
rescue
  error ->
    IO.puts(:stderr, Exception.format(:error, error, __STACKTRACE__))
    System.halt(1)
catch
  kind, reason ->
    IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
    System.halt(1)
end
