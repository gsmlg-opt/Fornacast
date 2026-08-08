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
      {_output, 0} -> load_built_nif!()
      {output, status} -> raise "test DirtyIo NIF build failed (#{status}):\n#{output}"
    end
  end

  def test_dirty_io_wait(_entered_path, _release_path),
    do: :erlang.nif_error(:nif_not_loaded)

  defp load_built_nif! do
    path =
      @target_dir
      |> Path.join("debug")
      |> Path.join(native_library_name())
      |> String.to_charlist()

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, reason} -> raise "test DirtyIo NIF load failed: #{inspect(reason)}"
    end
  end

  defp native_library_name do
    case :os.type() do
      {:win32, _} -> "fornacast_git_transport_test_dirty_io"
      {:unix, :darwin} -> "libfornacast_git_transport_test_dirty_io"
      {:unix, _} -> "libfornacast_git_transport_test_dirty_io"
    end
  end
end
