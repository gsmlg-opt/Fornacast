defmodule GitCore.BlobLimiterLimitsTest do
  use ExUnit.Case, async: false

  test "uses lower configured concurrency and reserved-byte ceilings by default" do
    original = Application.get_env(:git_core, :limits)

    configured =
      original
      |> Kernel.||([])
      |> Keyword.put(:blob_concurrency, 1)
      |> Keyword.put(:blob_reserved_bytes, 4)

    Application.put_env(:git_core, :limits, configured)
    on_exit(fn -> restore_limits(original) end)

    server =
      start_supervised!({GitCore.BlobLimiter, server: nil, wait_timeout: 0}, id: make_ref())

    assert {:ok, lease} = GitCore.BlobLimiter.acquire(4, server: server)

    assert {:error, %GitCore.Error{kind: :blob_busy}} =
             GitCore.BlobLimiter.acquire(0, server: server)

    assert :ok = GitCore.BlobLimiter.release(lease)

    assert {:error, %GitCore.Error{kind: :blob_too_large}} =
             GitCore.BlobLimiter.acquire(5, server: server)
  end

  defp restore_limits(nil), do: Application.delete_env(:git_core, :limits)
  defp restore_limits(limits), do: Application.put_env(:git_core, :limits, limits)
end
