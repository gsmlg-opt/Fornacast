defmodule GitTransport.TestDirtyIoNativeTest do
  use ExUnit.Case, async: true

  alias GitTransport.TestDirtyIoNative

  test "maps Cargo artifacts to BEAM-loadable platform filenames" do
    target_dir = Path.join(System.tmp_dir!(), "test-native-target")

    assert_paths(
      {:unix, :linux},
      target_dir,
      "libfornacast_git_transport_test_dirty_io.so",
      ".so"
    )

    assert_paths(
      {:unix, :darwin},
      target_dir,
      "libfornacast_git_transport_test_dirty_io.dylib",
      ".so"
    )

    assert_paths(
      {:win32, :nt},
      target_dir,
      "fornacast_git_transport_test_dirty_io.dll",
      ".dll"
    )
  end

  defp assert_paths(os_type, target_dir, cargo_filename, installed_suffix) do
    paths = TestDirtyIoNative.artifact_paths(os_type, target_dir, "fingerprint")
    base = "fornacast_git_transport_test_dirty_io"

    assert paths.cargo == Path.join([target_dir, "debug", cargo_filename])

    assert paths.installed ==
             Path.join([target_dir, "nif", "fingerprint", base <> installed_suffix])

    assert paths.load == Path.join([target_dir, "nif", "fingerprint", base])
  end
end
