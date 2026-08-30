defmodule Fornacast.LegacyTursoPreflightTest do
  use ExUnit.Case, async: false

  alias Fornacast.LegacyTursoPreflight

  @acknowledgement_env "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA"
  @legacy_path_env "FORNACAST_LEGACY_TURSO_DATABASE_PATH"

  setup do
    application_env =
      Map.new([:database_adapter, :legacy_turso_preflight, :repo_storage_root], fn key ->
        {key, Application.fetch_env(:fornacast, key)}
      end)

    system_env =
      Map.new([@acknowledgement_env, @legacy_path_env], fn key ->
        {key, System.fetch_env(key)}
      end)

    System.delete_env(@acknowledgement_env)
    System.delete_env(@legacy_path_env)

    on_exit(fn ->
      Enum.each(application_env, fn {key, value} -> restore_application_env(key, value) end)
      Enum.each(system_env, fn {key, value} -> restore_system_env(key, value) end)
    end)

    :ok
  end

  @tag :tmp_dir
  test "disabled preflight ignores an existing legacy database", %{tmp_dir: tmp_dir} do
    legacy_path = legacy_file!(tmp_dir)
    configure_preflight(false, "postgres", legacy_path)

    assert :ok = LegacyTursoPreflight.verify!()
  end

  @tag :tmp_dir
  test "enabled PostgreSQL preflight permits a missing legacy database", %{tmp_dir: tmp_dir} do
    legacy_path = Path.join(tmp_dir, "missing.db")
    configure_preflight(true, "postgres", legacy_path)

    assert :ok = LegacyTursoPreflight.verify!()
  end

  @tag :tmp_dir
  test "enabled PostgreSQL preflight rejects an unacknowledged legacy database", %{
    tmp_dir: tmp_dir
  } do
    legacy_path = legacy_file!(tmp_dir)
    configure_preflight(true, "postgresql", legacy_path)

    assert_raise RuntimeError, detection_message(legacy_path), fn ->
      LegacyTursoPreflight.verify!()
    end
  end

  @tag :tmp_dir
  test "only the exact acknowledgement value true permits a legacy database", %{tmp_dir: tmp_dir} do
    legacy_path = legacy_file!(tmp_dir)
    configure_preflight(true, "postgres", legacy_path)

    System.put_env(@acknowledgement_env, "true")
    assert :ok = LegacyTursoPreflight.verify!()

    for value <- ["TRUE", "True", "1", " true", "true "] do
      System.put_env(@acknowledgement_env, value)

      assert_raise RuntimeError, detection_message(legacy_path), fn ->
        LegacyTursoPreflight.verify!()
      end
    end
  end

  @tag :tmp_dir
  test "enabled Turso adapters ignore an existing legacy database", %{tmp_dir: tmp_dir} do
    legacy_path = legacy_file!(tmp_dir)

    for adapter <- ["turso", "libsql"] do
      configure_preflight(true, adapter, legacy_path)
      assert :ok = LegacyTursoPreflight.verify!()
    end
  end

  @tag :tmp_dir
  test "validate_path accepts and expands printable absolute paths", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "nested", "..", "legacy.db"])
    expanded_path = Path.expand(path)

    assert {:ok, ^expanded_path} = LegacyTursoPreflight.validate_path(path)
  end

  test "validate_path rejects unsafe paths" do
    invalid_paths = [
      "relative.db",
      "/tmp/legacy\0.db",
      "/tmp/legacy\n.db",
      "/tmp/legacy\u200B.db",
      <<"/tmp/legacy-", 255>>,
      "",
      nil,
      :not_a_path,
      "/" <> String.duplicate("a", 4096)
    ]

    for path <- invalid_paths do
      assert {:error, :invalid_path} = LegacyTursoPreflight.validate_path(path)
    end
  end

  test "invalid configured path raises a fixed message" do
    configure_preflight(true, "postgres", "relative-secret.db")

    assert_raise RuntimeError,
                 "FORNACAST_LEGACY_TURSO_DATABASE_PATH must be a printable absolute path",
                 fn -> LegacyTursoPreflight.verify!() end
  end

  @tag :tmp_dir
  test "detection error identifies the escaped path and action without reading file contents", %{
    tmp_dir: tmp_dir
  } do
    legacy_path = Path.join(tmp_dir, ~s(legacy"database.db))
    File.write!(legacy_path, "legacy-secret-content")
    configure_preflight(true, "postgres", legacy_path)

    error = assert_raise RuntimeError, fn -> LegacyTursoPreflight.verify!() end
    message = Exception.message(error)

    assert message == detection_message(legacy_path)
    assert message =~ inspect(legacy_path)
    assert message =~ "back it up"
    assert message =~ "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true"
    refute message =~ "legacy-secret-content"
  end

  @tag :tmp_dir
  test "prepare_start rejects legacy data before creating repository storage", %{tmp_dir: tmp_dir} do
    legacy_path = legacy_file!(tmp_dir)
    storage_root = Path.join(tmp_dir, "absent/repos")

    configure_preflight(true, "postgres", legacy_path)
    Application.put_env(:fornacast, :repo_storage_root, storage_root)
    refute File.exists?(storage_root)

    assert_raise RuntimeError, detection_message(legacy_path), fn ->
      Fornacast.Application.prepare_start()
    end

    refute File.exists?(storage_root)
  end

  defp configure_preflight(enabled, adapter, legacy_path) do
    Application.put_env(:fornacast, :legacy_turso_preflight, enabled)
    Application.put_env(:fornacast, :database_adapter, adapter)
    System.put_env(@legacy_path_env, legacy_path)
  end

  defp legacy_file!(tmp_dir) do
    path = Path.join(tmp_dir, "fornacast.db")
    File.write!(path, "legacy-secret-content")
    path
  end

  defp detection_message(path) do
    "legacy Turso database detected at #{inspect(path)}; back it up and set " <>
      "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true only after an intentional transition"
  end

  defp restore_application_env(key, {:ok, value}) do
    Application.put_env(:fornacast, key, value)
  end

  defp restore_application_env(key, :error) do
    Application.delete_env(:fornacast, key)
  end

  defp restore_system_env(key, {:ok, value}), do: System.put_env(key, value)
  defp restore_system_env(key, :error), do: System.delete_env(key)
end
