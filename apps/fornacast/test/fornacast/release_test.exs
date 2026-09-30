defmodule Fornacast.ReleaseTest do
  use ExUnit.Case, async: true

  test "exposes the release migration command" do
    assert {:module, Fornacast.Release} = Code.ensure_loaded(Fornacast.Release)
    assert function_exported?(Fornacast.Release, :migrate, 0)
    assert Application.fetch_env!(:fornacast, :ecto_repos) == [Fornacast.Repo]
  end

  test "routes the migrate release command through env.sh" do
    env_script = File.read!(Path.expand("../../../../rel/env.sh.eex", __DIR__))

    assert env_script =~ ~s(case "$RELEASE_COMMAND")
    assert env_script =~ "RELEASE_ROOT/bin/$RELEASE_NAME"
    assert env_script =~ "Fornacast.Release.migrate()"
  end
end
