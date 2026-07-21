defmodule FornacastAPI.HealthController do
  use FornacastAPI, :controller

  def show(conn, _params) do
    checks = %{
      app: :ok,
      database: database_check(),
      repository_storage: storage_check()
    }

    status = if Enum.all?(checks, fn {_key, value} -> value == :ok end), do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{status: if(status == 200, do: "ok", else: "degraded"), checks: checks})
  end

  defp database_check do
    case Ecto.Adapters.SQL.query(Fornacast.Repo, "select 1", []) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp storage_check do
    try do
      root = Fornacast.Storage.ensure_root!()
      suffix = System.unique_integer([:positive, :monotonic])
      probe = Path.join(root, ".api-health-#{suffix}")

      try do
        with :ok <- File.write(probe, "ok", [:write, :exclusive]),
             {:ok, "ok"} <- File.read(probe) do
          :ok
        else
          _reason -> :error
        end
      after
        File.rm(probe)
      end
    rescue
      _reason -> :error
    end
  end
end
