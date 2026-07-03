defmodule Fornacast.ConfigStoreTest do
  use ExUnit.Case, async: false

  alias Fornacast.ConfigStore

  test "stores app config values in Concord Turso" do
    key = "test:#{System.unique_integer([:positive, :monotonic])}"

    assert {:error, :not_found} = ConfigStore.fetch(key)
    assert {:ok, :fallback} = ConfigStore.get(key, :fallback)

    assert :ok = ConfigStore.put(key, %{enabled: true, limit: 5})
    assert {:ok, %{enabled: true, limit: 5}} = ConfigStore.fetch(key)
    assert {:ok, %{enabled: true, limit: 5}} = ConfigStore.get(key, :fallback)

    assert :ok = ConfigStore.delete(key)
    assert {:error, :not_found} = ConfigStore.fetch(key)
  end
end
