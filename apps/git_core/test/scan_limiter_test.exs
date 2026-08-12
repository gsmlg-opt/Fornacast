defmodule GitCore.ScanLimiterLimitsTest do
  use ExUnit.Case, async: false

  test "uses a lower configured concurrency ceiling by default" do
    original = Application.get_env(:git_core, :limits)
    Application.put_env(:git_core, :limits, Keyword.put(original || [], :scan_concurrency, 1))

    on_exit(fn -> restore_limits(original) end)

    server =
      start_supervised!({GitCore.ScanLimiter, server: nil, wait_timeout: 0}, id: make_ref())

    parent = self()

    holder =
      spawn(fn ->
        GitCore.ScanLimiter.with_permit(
          :configured_scan,
          fn ->
            send(parent, :scan_held)
            receive do: (:release -> :ok)
          end,
          server: server
        )
      end)

    assert_receive :scan_held

    assert {:error, %GitCore.Error{kind: :scan_busy}} =
             GitCore.ScanLimiter.with_permit(:configured_scan, fn -> :unexpected end,
               server: server
             )

    send(holder, :release)
  end

  defp restore_limits(nil), do: Application.delete_env(:git_core, :limits)
  defp restore_limits(limits), do: Application.put_env(:git_core, :limits, limits)
end
