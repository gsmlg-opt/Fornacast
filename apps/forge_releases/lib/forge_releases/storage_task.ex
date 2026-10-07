defmodule ForgeReleases.StorageTask do
  @moduledoc false

  def run(digest, fun, timeout \\ 30_000) do
    coordinator = self()

    task =
      Task.Supervisor.async_nolink(ForgeReleases.StorageTasks, fn ->
        {:ok, timer} = :timer.kill_after(timeout)

        try do
          ForgeBlobs.with_digest_lock(digest, coordinator, fn ->
            if Process.alive?(coordinator), do: fun.(), else: {:error, :unavailable}
          end)
        after
          :timer.cancel(timer)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :unavailable}
    end
  end
end
