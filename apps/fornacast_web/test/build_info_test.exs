defmodule FornacastWeb.BuildInfoTest do
  use ExUnit.Case, async: false

  alias FornacastWeb.BuildInfo

  test "reports the running application version and compiled environment" do
    info = BuildInfo.current()

    assert info.version == to_string(Application.spec(:fornacast_web, :vsn))
    assert {:ok, _} = Version.parse(info.version)
    assert info.environment == :test
    assert {:ok, _, _} = DateTime.from_iso8601(info.built_at)
  end

  test "runtime environment changes cannot replace embedded source metadata" do
    info = BuildInfo.current()

    for name <-
          ~w(FORNACAST_BUILD_GIT_REF FORNACAST_BUILD_GIT_COMMIT FORNACAST_BUILD_TIME FORNACAST_RELEASE_TIME) do
      previous = System.get_env(name)

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)

      System.put_env(name, "runtime-value")
    end

    assert BuildInfo.current() == info
  end
end
