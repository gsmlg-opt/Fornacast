defmodule GitTransport.TestDirtyIoNative do
  @moduledoc false

  @crate_dir Path.expand("native/test_dirty_io", __DIR__)
  @target_dir Path.join(Mix.Project.build_path(), "git_transport_test_native")

  def load! do
    case System.cmd("cargo", ["build", "--locked", "--quiet"],
           cd: @crate_dir,
           env: [{"CARGO_TARGET_DIR", @target_dir}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> install_and_load_built_nif!()
      {output, status} -> raise "test DirtyIo NIF build failed (#{status}):\n#{output}"
    end
  end

  @doc false
  def artifact_paths(os_type, target_dir, fingerprint) do
    {cargo_filename, installed_suffix} = platform_filenames(os_type)
    basename = "fornacast_git_transport_test_dirty_io"
    installed_base = Path.join([target_dir, "nif", fingerprint, basename])

    %{
      cargo: Path.join([target_dir, "debug", cargo_filename]),
      installed: installed_base <> installed_suffix,
      load: installed_base
    }
  end

  def test_dirty_io_wait(_entered_path, _release_path),
    do: :erlang.nif_error(:nif_not_loaded)

  defp install_and_load_built_nif! do
    os_type = :os.type()
    source = artifact_paths(os_type, @target_dir, "source").cargo

    fingerprint =
      source |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    paths = artifact_paths(os_type, @target_dir, fingerprint)

    install_artifact!(paths.cargo, paths.installed)

    case :erlang.load_nif(String.to_charlist(paths.load), 0) do
      :ok -> :ok
      {:error, reason} -> raise "test DirtyIo NIF load failed: #{inspect(reason)}"
    end
  end

  defp install_artifact!(source, destination) do
    unless File.regular?(destination) do
      File.mkdir_p!(Path.dirname(destination))

      temporary =
        destination <>
          ".tmp.#{System.pid()}.#{System.unique_integer([:positive, :monotonic])}"

      try do
        File.cp!(source, temporary)

        case File.rename(temporary, destination) do
          :ok -> :ok
          {:error, reason} -> resolve_install_race!(destination, reason)
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp resolve_install_race!(destination, reason) do
    unless File.regular?(destination) do
      raise File.Error, reason: reason, action: "install test DirtyIo NIF", path: destination
    end
  end

  defp platform_filenames({:win32, _}),
    do: {"fornacast_git_transport_test_dirty_io.dll", ".dll"}

  defp platform_filenames({:unix, :darwin}),
    do: {"libfornacast_git_transport_test_dirty_io.dylib", ".so"}

  defp platform_filenames({:unix, _}),
    do: {"libfornacast_git_transport_test_dirty_io.so", ".so"}
end
