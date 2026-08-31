defmodule ForgeAccounts.GitHubIdentityWrite do
  @moduledoc false

  @turso_busy_attempts 12
  @turso_busy_backoff_ms 5

  def with_retry(fun) when is_function(fun, 0) do
    attempts = if turso?(), do: @turso_busy_attempts, else: 1
    retry(fun, attempts)
  end

  defp retry(fun, attempts_remaining) do
    fun.()
  rescue
    error in Turso.Error ->
      if turso?() and error.code == :busy and attempts_remaining > 1 do
        attempt = @turso_busy_attempts - attempts_remaining + 1
        Process.sleep(attempt * @turso_busy_backoff_ms)
        retry(fun, attempts_remaining - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp turso? do
    Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"]
  end
end
