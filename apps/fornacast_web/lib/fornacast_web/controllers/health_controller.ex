defmodule FornacastWeb.HealthController do
  use FornacastWeb, :controller

  def show(conn, _params) do
    checks = %{
      app: :ok,
      database: database_check(),
      repository_storage: storage_check(),
      ssh_daemon: ssh_daemon_check()
    }

    status =
      if Enum.all?(checks, fn {_key, value} -> value in [:ok, :disabled] end), do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{status: if(status == 200, do: "ok", else: "degraded"), checks: checks})
  end

  defp database_check do
    case Ecto.Adapters.SQL.query(Fornacast.Repo, "select 1", []) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp storage_check do
    root = Fornacast.Storage.ensure_root!()
    probe = Path.join(root, ".health")

    with :ok <- File.write(probe, "ok"),
         {:ok, "ok"} <- File.read(probe),
         :ok <- File.rm(probe) do
      :ok
    else
      _ -> :error
    end
  end

  defp ssh_daemon_check do
    if Fornacast.Config.ssh_enabled?() do
      case Process.whereis(GitTransport.Daemon) do
        nil ->
          :error

        _pid ->
          case GitTransport.ssh_daemon_info() do
            {:ok, _info} -> :ok
            {:error, _reason} -> :error
          end
      end
    else
      :disabled
    end
  end
end
