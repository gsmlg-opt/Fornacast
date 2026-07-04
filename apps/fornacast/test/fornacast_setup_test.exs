defmodule Fornacast.SetupTest do
  use ExUnit.Case, async: false

  alias Fornacast.Setup

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)
    Setup.reset!()

    on_exit(fn ->
      Setup.reset!()
      Ecto.Adapters.SQL.Sandbox.checkin(Fornacast.Repo)
    end)

    :ok
  end

  test "starts uninitialized" do
    refute Setup.initialized?()
  end

  test "mark_initialized! records the flag and reports initialized" do
    actor = %{id: 1}
    assert :ok = Setup.mark_initialized!(actor)
    assert Setup.initialized?()
    assert {:ok, timestamp} = Fornacast.ConfigStore.get("initialized_at")
    assert is_binary(timestamp)
  end

  test "force_initialized! sets the latch without writing the flag" do
    assert :ok = Setup.force_initialized!()
    assert Setup.initialized?()
    assert {:ok, nil} = Fornacast.ConfigStore.get("initialized_at")
  end

  test "reset! clears latch and flag" do
    Setup.mark_initialized!(%{id: 1})
    assert Setup.initialized?()
    assert :ok = Setup.reset!()
    refute Setup.initialized?()
  end

  test "a pre-set flag alone reports initialized (durable record survives restart)" do
    Fornacast.ConfigStore.put("initialized_at", "2026-07-04T00:00:00Z")
    Setup.reset_latch_only!()
    assert Setup.initialized?()
  end
end
